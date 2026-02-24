-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 2 — FORM RESPONSE PATCH 03: FINAL SCORING HARDENING
-- =============================================================================
-- Apply after: all prior Phase 2 files + patch R01 + patch R02
-- This is the final patch before Phase 2 is fully frozen.
-- =============================================================================
--
-- LOCKED DECISIONS
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-R10] log_score() must block on locked responses.
--           "locked" means absolutely final — no recomputation permitted,
--           not even via the system scoring function.
--           Without this, the governance matrix has a semantic mismatch:
--           matrix says locked=FROZEN(all), but log_score() could still write.
--
-- [FIX-R11] enforce_response_lock_immutability() and enforce_system_only_score_guard()
--           should acquire FOR SHARE on form_templates when reading
--           scoring_finalization_point. Prevents concurrent admin policy change
--           from racing with a score write mid-transaction.
--           Low practical risk (template policy changes are rare + admin-only),
--           but architecturally cleaner for a regulated system.
-- =============================================================================


-- =============================================================================
-- [FIX-R10] log_score() — block scoring on locked responses
-- =============================================================================

CREATE OR REPLACE FUNCTION log_score(
    p_response_id       UUID,
    p_computed_score    NUMERIC,
    p_interpretation    TEXT DEFAULT NULL,
    p_metadata          JSONB DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_institute_id  UUID;
    v_patient_id    UUID;
    v_status        TEXT;
BEGIN
    -- Activate the system_only guard bypass for this transaction (local to txn)
    PERFORM set_config('app.scoring_function_active', 'true', TRUE);

    -- [FIX-R10] Acquire row lock and check status before writing
    -- FOR UPDATE: prevents concurrent lock transition racing with this score write
    SELECT institute_id, patient_id, response_status
    INTO v_institute_id, v_patient_id, v_status
    FROM form_responses
    WHERE id = p_response_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'log_score: form_response % not found.',
            p_response_id;
    END IF;

    -- [FIX-R10] Locked = absolutely final. No recomputation permitted.
    -- Governance matrix: locked → FROZEN (all), including system scoring.
    -- To correct a locked response score, use the amendment workflow:
    -- create a new response with supersedes_response_id (Phase 3).
    IF v_status = 'locked' THEN
        RAISE EXCEPTION
            '[FIX-R10] log_score: form_response % is locked and cannot be re-scored. '
            '"locked" means absolutely final — no recomputation is permitted, '
            'including via the system scoring function. '
            'To correct a locked response, use the amendment workflow: '
            'create a new response with supersedes_response_id referencing this one.',
            p_response_id;
    END IF;

    -- Write the system-calculated score
    UPDATE form_responses SET
        computed_score       = p_computed_score,
        score_interpretation = p_interpretation,
        scoring_method       = 'system_auto',
        scored_by            = NULL,
        scored_at            = NOW()
    WHERE id = p_response_id;

    -- Audit the scoring event
    PERFORM log_audit(
        v_institute_id,
        NULL,           -- actor = system/NULL for automated scoring
        NULL,
        'SCORE_COMPUTED',
        'form_responses',
        p_response_id,
        NULL,
        jsonb_build_object(
            'computed_score',      p_computed_score,
            'score_interpretation', p_interpretation,
            'scoring_method',      'system_auto',
            'response_status',     v_status
        ),
        p_metadata
    );

    -- Reset flag (redundant — set_config TRUE = transaction-local, but explicit)
    PERFORM set_config('app.scoring_function_active', 'false', TRUE);
END;
$$;

COMMENT ON FUNCTION log_score(UUID, NUMERIC, TEXT, JSONB) IS
    '[FIX-R10] Locked responses cannot be re-scored — not even by the system. '
    '"locked" = absolutely final per governance matrix. '
    'Amendment workflow (Phase 3 supersedes_response_id) is the only correction path. '
    'FOR UPDATE acquired before status check — serializes with concurrent lock transitions. '
    'Still the ONLY permitted write path for system_only scored instruments.';


-- =============================================================================
-- [FIX-R11] FOR SHARE on template policy reads in immutability triggers
-- =============================================================================
-- Two functions read scoring_finalization_point without locking:
--   enforce_response_lock_immutability()
--   enforce_system_only_score_guard()
-- Adding FOR SHARE prevents concurrent admin template policy change from
-- producing an inconsistent read mid-score-write.
-- Practical risk: very low (template changes are rare, admin-only, published
-- versions are immutable so finalization_point is stable post-publish).
-- Architectural posture: correct for regulated clinical systems.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_response_lock_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_finalization_point TEXT;
    v_score_frozen       BOOLEAN;
BEGIN
    -- [FIX-R11] FOR SHARE on template: prevents concurrent policy change racing
    -- with this immutability check. Shared lock — allows concurrent reads,
    -- blocks concurrent writes to scoring_finalization_point.
    SELECT ft.scoring_finalization_point INTO v_finalization_point
    FROM form_templates ft
    JOIN form_versions fv ON fv.form_template_id = ft.id
    WHERE fv.id = NEW.form_version_id
    FOR SHARE OF ft;

    -- Governance matrix: determine score freeze point per instrument policy
    v_score_frozen := CASE v_finalization_point
        WHEN 'submission'  THEN OLD.response_status IN ('submitted', 'reviewed', 'locked')
        WHEN 'review'      THEN OLD.response_status IN ('reviewed', 'locked')
        WHEN 'system_only' THEN TRUE
        ELSE TRUE   -- safe default: freeze immediately if unknown policy
    END;

    -- Case A: Row already in frozen status — block core clinical field changes
    IF OLD.response_status IN ('submitted', 'reviewed', 'locked') THEN

        IF NEW.form_version_id        != OLD.form_version_id               OR
           NEW.patient_id             IS DISTINCT FROM OLD.patient_id      OR
           NEW.context_ref_id         IS DISTINCT FROM OLD.context_ref_id  OR
           NEW.context_type_id        != OLD.context_type_id               OR
           NEW.response_mode          != OLD.response_mode                 OR
           NEW.started_at             != OLD.started_at                    OR
           NEW.submitted_at           IS DISTINCT FROM OLD.submitted_at    OR
           NEW.administered_by        IS DISTINCT FROM OLD.administered_by OR
           NEW.administration_mode    IS DISTINCT FROM OLD.administration_mode
        THEN
            RAISE EXCEPTION
                'form_response % has status=% — core clinical fields are frozen. '
                'Use amendment workflow: new response with supersedes_response_id.',
                OLD.id, OLD.response_status;
        END IF;

        IF v_score_frozen AND NEW.computed_score IS DISTINCT FROM OLD.computed_score THEN
            RAISE EXCEPTION
                'computed_score on response % is frozen per instrument policy '
                '(scoring_finalization_point=%, status=%). '
                'submission: frozen from submitted. '
                'review: frozen from reviewed. '
                'system_only: always frozen for users — use log_score().',
                OLD.id, v_finalization_point, OLD.response_status;
        END IF;

        IF v_score_frozen THEN
            IF NEW.scoring_method IS DISTINCT FROM OLD.scoring_method OR
               NEW.scored_by      IS DISTINCT FROM OLD.scored_by      OR
               NEW.scored_at      IS DISTINCT FROM OLD.scored_at
            THEN
                RAISE EXCEPTION
                    'Scoring provenance on response % is frozen per instrument policy (%).',
                    OLD.id, v_finalization_point;
            END IF;
        END IF;

    END IF;

    -- Case B: in_progress → submitted/reviewed/locked transition
    -- Legitimate writes (setting submitted_at + status + score simultaneously).
    -- rfv_update RLS independently prevents field value changes during transition.
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION enforce_system_only_score_guard()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_finalization_point TEXT;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.computed_score IS NULL THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' AND
       NEW.computed_score IS NOT DISTINCT FROM OLD.computed_score THEN
        RETURN NEW;
    END IF;

    -- [FIX-R11] FOR SHARE: consistent read of policy under concurrent admin changes
    SELECT ft.scoring_finalization_point INTO v_finalization_point
    FROM form_templates ft
    JOIN form_versions fv ON fv.form_template_id = ft.id
    WHERE fv.id = NEW.form_version_id
    FOR SHARE OF ft;

    IF v_finalization_point = 'system_only' THEN
        IF current_setting('app.scoring_function_active', TRUE) != 'true' THEN
            RAISE EXCEPTION
                'computed_score on response % cannot be set directly. '
                'Instrument policy = system_only. '
                'Score must be written via log_score() only.',
                COALESCE(NEW.id, OLD.id);
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_system_only_score_guard() IS
    '[FIX-R11] FOR SHARE on form_templates prevents concurrent policy change '
    'from producing inconsistent finalization_point read during score write. '
    'Shared lock: allows concurrent reads, blocks concurrent admin writes.';

COMMENT ON FUNCTION enforce_response_lock_immutability() IS
    '[FIX-R11] FOR SHARE on form_templates: consistent policy read under concurrency. '
    '[FIX-R10] Governance matrix: locked = absolutely final for all instruments. '
    'submission: score frozen at submitted. '
    'review: score frozen at reviewed. '
    'system_only: always frozen for users, log_score() blocked on locked.';


-- =============================================================================
-- PATCH R03 SUMMARY
-- =============================================================================
--
--  Fix      | What Changed
-- ──────────┼─────────────────────────────────────────────────────────────────
--  FIX-R10  | log_score() REPLACED
--            | Acquires FOR UPDATE on response row before status check
--            | Raises EXCEPTION if response_status = 'locked'
--            | "locked" now means absolutely final — system cannot re-score
--
--  FIX-R11  | enforce_response_lock_immutability() REPLACED
--            | enforce_system_only_score_guard() REPLACED
--            | Both now use FOR SHARE OF ft on form_templates join
--            | Prevents concurrent admin policy change racing with score write
--
-- =============================================================================
-- COMPLETE GOVERNANCE MATRIX — FINAL AND FROZEN
-- =============================================================================
--
--  Status       | submission | review     | system_only
-- ──────────────┼────────────┼────────────┼────────────────────────────
--  in_progress  | editable   | editable   | log_score() only
--  submitted    | FROZEN     | editable   | log_score() only
--  reviewed     | FROZEN     | FROZEN     | log_score() only
--  locked       | FROZEN     | FROZEN     | FROZEN (log_score() blocked)
--
-- Enforcement layers (all independent):
--   1. fr_update RLS                          in_progress gate
--   2. rfv_update RLS                         in_progress gate (field values)
--   3. enforce_response_lock_immutability()   frozen-state + policy-aware
--   4. enforce_field_value_response_lock()    field value write gate
--   5. enforce_system_only_score_guard()      system_only direct-write block
--   6. log_score() internal status check      locked response block
--
-- =============================================================================
-- PHASE 2 — FULLY FROZEN MIGRATION SEQUENCE
-- =============================================================================
--
--  1.  phase1_foundation.sql
--  2.  phase1_patch01.sql
--  3.  phase1_patch02.sql
--  4.  phase2_form_definition.sql
--  5.  phase2_form_definition_patch01.sql
--  6.  phase2_form_definition_patch02.sql
--  7.  phase2_form_definition_patch03.sql
--  8.  phase2_form_responses.sql
--  9.  phase2_form_responses_patch01.sql
--  10. phase2_form_responses_patch02.sql
--  11. phase2_form_responses_patch03.sql   ← this file
--
-- Phase 2 is production-frozen. No further patches expected.
--
-- Phase 3 entry obligations (must be first three actions in Phase 3):
--   [O1] Replace validate_response_context_ref()
--        Unblocks session and evaluation context types on form_responses
--   [O2] Replace validate_case_role_scope_ref_partial()
--        Unblocks program scope in case_role_assignments
--   [O3] Add supersedes_response_id to form_responses
--        Closes the amendment workflow loop
--   Then: therapy_type_registry, therapy_programs, session_records,
--         evaluations, milestones, plan_change_requests, case_conferences
-- =============================================================================
