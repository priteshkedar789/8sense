-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 3 — CLINICAL EVENTS PATCH 01: STRUCTURAL ENFORCEMENT GAPS
-- =============================================================================
-- Apply after: phase3_clinical_events.sql
-- =============================================================================
--
-- FIXES IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-CE1] Composite FK mismatch in milestone_progress_entries.
--           Was: FOREIGN KEY (milestone_id, therapy_program_id)
--                REFERENCES program_milestones(id, institute_id)
--           The column pairs do not match semantically.
--           therapy_program_id ≠ institute_id.
--           Correct: FOREIGN KEY (milestone_id, institute_id)
--                    REFERENCES program_milestones(id, institute_id)
--           This ensures the milestone belongs to the same institute
--           as the progress entry, using the existing uq_pm_id_institute index.
--
-- [FIX-CE2] Direct INSERT into therapy_program_versions not blocked.
--           Governance stance: "every version on an active program must
--           originate from an approved plan_change_request."
--           Without a structural gate, a SECURITY DEFINER function or
--           platform admin can insert a version directly, bypassing PCR.
--           Fix: trigger blocks direct INSERT on active/paused programs
--           unless the insert is being performed by the PCR implementation
--           trigger (session variable gate, same pattern as log_score()).
-- =============================================================================


-- =============================================================================
-- [FIX-CE1] Correct composite FK on milestone_progress_entries
-- =============================================================================

ALTER TABLE milestone_progress_entries
    DROP CONSTRAINT IF EXISTS milestone_progress_entries_milestone_id_therapy_program_id_fkey;

-- Correct composite FK: milestone must exist in same institute as the entry
ALTER TABLE milestone_progress_entries
    ADD CONSTRAINT fk_mpe_milestone_institute
    FOREIGN KEY (milestone_id, institute_id)
    REFERENCES program_milestones(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

COMMENT ON CONSTRAINT fk_mpe_milestone_institute ON milestone_progress_entries IS
    '[FIX-CE1] Corrected composite FK. Previous version incorrectly paired '
    '(milestone_id, therapy_program_id) with program_milestones(id, institute_id). '
    'Correct pairing: (milestone_id, institute_id) → program_milestones(id, institute_id). '
    'Ensures milestone belongs to same institute as progress entry. '
    'Uses uq_pm_id_institute unique constraint as FK target.';

-- Also add direct program consistency check via trigger
-- (the composite FK above ensures institute, but not that the milestone
-- actually belongs to the stated therapy_program)
CREATE OR REPLACE FUNCTION enforce_progress_entry_milestone_program_consistency()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_milestone_program UUID;
BEGIN
    SELECT therapy_program_id INTO v_milestone_program
    FROM program_milestones
    WHERE id = NEW.milestone_id;

    IF v_milestone_program != NEW.therapy_program_id THEN
        RAISE EXCEPTION
            '[FIX-CE1] milestone_progress_entry: milestone % belongs to program %, '
            'but entry references program %. '
            'Progress entries must reference a milestone from the same program.',
            NEW.milestone_id, v_milestone_program, NEW.therapy_program_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_mpe_program_consistency
    BEFORE INSERT ON milestone_progress_entries
    FOR EACH ROW
    EXECUTE FUNCTION enforce_progress_entry_milestone_program_consistency();

COMMENT ON TRIGGER trg_mpe_program_consistency ON milestone_progress_entries IS
    '[FIX-CE1] Ensures milestone.therapy_program_id matches entry.therapy_program_id. '
    'Composite FK ensures institute boundary. '
    'This trigger ensures program-level consistency within that boundary. '
    'Together: no cross-institute, no cross-program milestone-entry attachment.';


-- =============================================================================
-- [FIX-CE2] therapy_program_versions direct insert guard
-- =============================================================================
-- Governance: every version on an active/paused program must originate
-- from an approved plan_change_request via the PCR implementation trigger.
-- Planned/draft programs may have versions created directly (initial planning).
-- Completed/discontinued programs are fully frozen — no new versions.
--
-- Same session-variable pattern as log_score() SECURITY DEFINER guard.
-- PCR trigger sets app.pcr_version_creation_active = 'true' before insert.
-- =============================================================================

-- Update the PCR implementation trigger to set the session variable
CREATE OR REPLACE FUNCTION create_program_version_on_pcr_implementation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_new_version_id    UUID;
    v_prog              therapy_programs%ROWTYPE;
    v_request_type_code TEXT;
BEGIN
    IF NOT (OLD.pcr_status = 'approved' AND NEW.pcr_status = 'implemented') THEN
        RETURN NEW;
    END IF;

    -- [FIX-CE2] Activate the version creation bypass for this transaction
    PERFORM set_config('app.pcr_version_creation_active', 'true', TRUE);

    SELECT * INTO v_prog FROM therapy_programs WHERE id = NEW.therapy_program_id;
    SELECT code INTO v_request_type_code FROM plan_change_request_types WHERE id = NEW.request_type_id;

    v_new_version_id := generate_uuidv7();

    INSERT INTO therapy_program_versions (
        id, therapy_program_id, institute_id,
        change_reason, change_summary,
        program_status_snapshot, intended_frequency_snapshot,
        session_duration_snapshot, clinical_notes,
        effective_from, created_by
    ) VALUES (
        v_new_version_id,
        NEW.therapy_program_id,
        NEW.institute_id,
        v_request_type_code,
        NEW.change_summary,
        v_prog.program_status,
        v_prog.intended_frequency_per_week,
        v_prog.intended_session_duration_minutes,
        NEW.clinical_rationale,
        NOW(),
        NEW.reviewed_by
    );

    NEW.resulting_version_id := v_new_version_id;
    NEW.implemented_at := NOW();

    -- Reset flag (redundant — transaction-local, but explicit)
    PERFORM set_config('app.pcr_version_creation_active', 'false', TRUE);

    RETURN NEW;
END;
$$;

-- Guard trigger: block direct version inserts on active/paused programs
CREATE OR REPLACE FUNCTION enforce_program_version_pcr_gate()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_program_status TEXT;
BEGIN
    SELECT program_status INTO v_program_status
    FROM therapy_programs
    WHERE id = NEW.therapy_program_id;

    -- planned/draft programs: direct version creation allowed (initial planning)
    IF v_program_status = 'planned' THEN
        RETURN NEW;
    END IF;

    -- completed/discontinued: no new versions under any circumstances
    IF v_program_status IN ('completed', 'discontinued') THEN
        RAISE EXCEPTION
            '[FIX-CE2] therapy_program % is % — no new versions may be created. '
            'Completed and discontinued programs are fully frozen.',
            NEW.therapy_program_id, v_program_status;
    END IF;

    -- active/paused: only allowed via PCR implementation trigger
    IF v_program_status IN ('active', 'paused') THEN
        IF current_setting('app.pcr_version_creation_active', TRUE) != 'true' THEN
            RAISE EXCEPTION
                '[FIX-CE2] therapy_program_version cannot be created directly '
                'on program % (status=%). '
                'All version changes on active programs must originate from an '
                'approved plan_change_request. '
                'Submit a PCR and implement it to create a new program version.',
                NEW.therapy_program_id, v_program_status;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_program_version_pcr_gate
    BEFORE INSERT ON therapy_program_versions
    FOR EACH ROW
    EXECUTE FUNCTION enforce_program_version_pcr_gate();

COMMENT ON TRIGGER trg_program_version_pcr_gate ON therapy_program_versions IS
    '[FIX-CE2] Enforces PCR governance on program version creation. '
    'planned programs: direct version creation allowed (initial planning). '
    'active/paused programs: only via PCR implementation trigger. '
    '  - PCR trigger sets app.pcr_version_creation_active=true (txn-local). '
    '  - Direct inserts (including SECURITY DEFINER) raise exception. '
    'completed/discontinued: no new versions under any circumstances. '
    'Same session-variable gate pattern as log_score() for system_only scoring.';

COMMENT ON FUNCTION enforce_program_version_pcr_gate() IS
    '[FIX-CE2] Three-way gate based on program status: '
    'planned → allowed (initial planning workflow). '
    'active/paused → PCR gate (app.pcr_version_creation_active must be true). '
    'completed/discontinued → always blocked. '
    'Structural enforcement of governance principle: '
    '"every version on an active program has an approval trail."';


-- =============================================================================
-- PATCH CE01 SUMMARY
-- =============================================================================
--
--  Fix      | What Changed
-- ──────────┼─────────────────────────────────────────────────────────────────
--  FIX-CE1  | fk_mpe_milestone_institute ADDED (corrects column mismatch)
--            | trg_mpe_program_consistency ADDED
--            | milestone → program consistency enforced at two layers
--
--  FIX-CE2  | create_program_version_on_pcr_implementation() REPLACED
--            | Sets app.pcr_version_creation_active=true before insert
--            | enforce_program_version_pcr_gate() function + trigger ADDED
--            | Direct version insert on active/paused programs structurally blocked
--            | planned programs: direct insert allowed
--            | completed/discontinued: always blocked
--
-- =============================================================================
-- PHASE 3 — FULLY FROZEN
-- =============================================================================
--
--  Guarantee                               | Enforcement
-- ─────────────────────────────────────────┼──────────────────────────────────
--  Milestone entry in same institute       | Composite FK (FIX-CE1)
--  Milestone entry in same program         | Trigger (FIX-CE1)
--  Session-linked entries: completed only  | Trigger (session integrity)
--  Session-linked entries: same patient    | Trigger (session integrity)
--  Program version on active = PCR only   | Trigger + session variable (FIX-CE2)
--  Completed programs: no new versions     | Trigger (FIX-CE2)
--  PCR lifecycle forward-only              | Trigger
--  PCR → version: atomic creation         | BEFORE UPDATE trigger
--  PCR implemented → version ID not null  | CHECK constraint
--  Case conference freeze at reviewed      | Trigger
--  Milestone header freeze at activation  | Trigger
--  Progress entries append-only            | Trigger
--
-- All three Phase 2 entry obligations closed.
-- All Phase 3 reviewer-identified structural issues resolved.
-- Phase 3 is production-frozen.
--
-- Complete Phase 3 migration (8 files):
--   phase3_clinical_core_foundation.sql
--   phase3_clinical_core_foundation_patch01.sql
--   phase3_session_records.sql
--   phase3_session_records_patch01.sql
--   phase3_evaluations.sql
--   phase3_evaluations_patch01.sql
--   phase3_clinical_events.sql
--   phase3_clinical_events_patch01.sql   ← this file
-- =============================================================================
