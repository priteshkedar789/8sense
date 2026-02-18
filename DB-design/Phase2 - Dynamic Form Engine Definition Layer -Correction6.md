-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 2 — FORM RESPONSE PATCH 02: INSTRUMENT-DEFINED SCORING GOVERNANCE
-- =============================================================================
-- Apply after: phase2_form_responses.sql + phase2_form_responses_patch01.sql
-- =============================================================================
--
-- LOCKED CLINICAL GOVERNANCE DECISIONS
-- ─────────────────────────────────────────────────────────────────────────────
-- Scoring finalization is instrument-defined, not status-defined globally.
-- Three finalization points, no others:
--   'submission'   — computed_score frozen at submission (e.g. CARS-2 auto-score)
--   'review'       — computed_score mutable until reviewed (e.g. Vineland-3)
--   'system_only'  — computed_score never user-editable (derived scores)
--
-- Scoring source is explicitly tracked per response:
--   scoring_method: 'system_auto' | 'clinician_entered' | 'supervisor_validated'
--   scored_by:      NULL (system) or UUID (human)
--   scored_at:      timestamp of scoring event
--
-- Governance matrix:
--   Status       | submission instrument | review instrument | system_only
--   in_progress  | editable              | editable          | no manual score
--   submitted    | FROZEN                | editable          | no manual score
--   reviewed     | FROZEN                | FROZEN            | no manual score
--   locked       | FROZEN                | FROZEN            | FROZEN
--
-- ─────────────────────────────────────────────────────────────────────────────
-- CHANGES IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-R6]  form_templates: add scoring_finalization_point column.
--           Instrument policy is schema-encoded, not application-assumed.
--
-- [FIX-R7]  form_responses: add scoring_method column.
--           Audit trail explicitly distinguishes auto/clinician/supervisor scoring.
--
-- [FIX-R8]  enforce_response_lock_immutability() — full rewrite.
--           Trigger now consults scoring_finalization_point before deciding
--           whether computed_score is mutable at the current status transition.
--           Trigger condition clarified per Observation 1 (semantic precision).
--
-- [FIX-R9]  system_only scoring guard.
--           Prevents any user from directly setting computed_score when
--           scoring_finalization_point = 'system_only'.
--           Score must be written via log_score() SECURITY DEFINER function only.
-- =============================================================================


-- =============================================================================
-- [FIX-R6] form_templates — scoring_finalization_point
-- =============================================================================

ALTER TABLE form_templates
    ADD COLUMN scoring_finalization_point TEXT NOT NULL DEFAULT 'submission'
    CONSTRAINT chk_scoring_finalization_point
        CHECK (scoring_finalization_point IN ('submission', 'review', 'system_only'));

COMMENT ON COLUMN form_templates.scoring_finalization_point IS
    '[FIX-R6] Instrument-defined scoring governance policy. '
    'submission  : computed_score frozen when response_status → submitted. '
    '              Example: CARS-2 (auto-calculated at submission). '
    'review      : computed_score mutable until response_status → reviewed. '
    '              Example: Vineland-3 (supervisor validates raw domain sums). '
    'system_only : computed_score never user-editable. '
    '              Written only by log_score() SECURITY DEFINER function. '
    '              Example: derived composite scores computed from other instruments. '
    'Default: submission — safest posture for new instruments.';


-- =============================================================================
-- [FIX-R7] form_responses — scoring_method
-- =============================================================================

ALTER TABLE form_responses
    ADD COLUMN scoring_method TEXT
    CONSTRAINT chk_scoring_method
        CHECK (scoring_method IN ('system_auto', 'clinician_entered', 'supervisor_validated'));

COMMENT ON COLUMN form_responses.scoring_method IS
    '[FIX-R7] Records how computed_score was produced for this response. '
    'system_auto          : scored_by IS NULL (background system calculation). '
    'clinician_entered    : scored_by = clinician UUID (manual entry at submission). '
    'supervisor_validated : scored_by = supervisor UUID (validated during review). '
    'NULL when is_scored_form = FALSE or score not yet computed. '
    'Makes audit trail self-describing — investigators can distinguish '
    'auto-scores from human-validated scores without application-layer inference.';

-- Integrity: scored_by must be NULL when scoring_method is system_auto
ALTER TABLE form_responses
    ADD CONSTRAINT chk_system_auto_no_scorer
        CHECK (
            scoring_method != 'system_auto'
            OR scored_by IS NULL
        );

-- Integrity: human-entered scores must have a scorer
ALTER TABLE form_responses
    ADD CONSTRAINT chk_human_score_requires_scorer
        CHECK (
            scoring_method NOT IN ('clinician_entered', 'supervisor_validated')
            OR scored_by IS NOT NULL
        );

COMMENT ON CONSTRAINT chk_system_auto_no_scorer ON form_responses IS
    '[FIX-R7] System-calculated scores have no human scorer. '
    'Prevents spurious scored_by values on automated scoring events.';

COMMENT ON CONSTRAINT chk_human_score_requires_scorer ON form_responses IS
    '[FIX-R7] Human scoring events must identify the scorer. '
    'Ensures accountability for clinician_entered and supervisor_validated scores.';


-- =============================================================================
-- [FIX-R8] Immutability trigger — full rewrite with instrument policy
-- =============================================================================
-- Two improvements over Patch R01 version:
--   1. Trigger now reads scoring_finalization_point from form_templates
--      to determine whether computed_score is mutable at this transition.
--   2. Trigger condition uses explicit transition logic (Observation 1):
--      distinguishes frozen-state edits from transition-time edits.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_response_lock_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_finalization_point TEXT;
    v_score_frozen       BOOLEAN;
BEGIN
    -- ── Step 1: Determine instrument scoring policy ───────────────────────────
    SELECT ft.scoring_finalization_point INTO v_finalization_point
    FROM form_templates ft
    JOIN form_versions fv ON fv.form_template_id = ft.id
    WHERE fv.id = NEW.form_version_id;

    -- ── Step 2: Determine whether computed_score is frozen at this transition ─
    -- Governance matrix:
    --   submission  : frozen once OLD.status IN (submitted, reviewed, locked)
    --   review      : frozen once OLD.status IN (reviewed, locked)
    --   system_only : frozen always (any status) — managed by log_score() only
    v_score_frozen := CASE v_finalization_point
        WHEN 'submission'  THEN OLD.response_status IN ('submitted', 'reviewed', 'locked')
        WHEN 'review'      THEN OLD.response_status IN ('reviewed', 'locked')
        WHEN 'system_only' THEN TRUE   -- always frozen for user edits
        ELSE TRUE                       -- default safe: freeze immediately
    END;

    -- ── Step 3: Enforce immutability on frozen rows ───────────────────────────
    -- [Observation 1 semantic clarity] Two distinct cases:
    --   Case A: Row is already in a frozen status (no transition happening)
    --   Case B: Row is transitioning from in_progress → frozen status
    --           In this case, some fields may legitimately change simultaneously
    --           (e.g. setting submitted_at + response_status in same UPDATE).
    --           The field-change check catches illegitimate simultaneous changes.

    IF OLD.response_status IN ('submitted', 'reviewed', 'locked') THEN
        -- Case A: row already frozen — block all core clinical field changes

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
                '[FIX-R8] form_response % has status=% — core clinical fields are frozen. '
                'To correct submitted data, use the amendment workflow: '
                'create a new response with supersedes_response_id referencing this one.',
                OLD.id, OLD.response_status;
        END IF;

        -- Score immutability: consult instrument policy
        IF v_score_frozen AND NEW.computed_score IS DISTINCT FROM OLD.computed_score THEN
            RAISE EXCEPTION
                '[FIX-R8] computed_score on response % is frozen per instrument policy '
                '(scoring_finalization_point=%). '
                'Current status: %. '
                'submission instruments: score frozen at submission. '
                'review instruments: score frozen after review. '
                'system_only instruments: score never user-editable — use log_score().',
                OLD.id, v_finalization_point, OLD.response_status;
        END IF;

        -- Also freeze scoring_method and scored_by once score is frozen
        IF v_score_frozen THEN
            IF NEW.scoring_method IS DISTINCT FROM OLD.scoring_method OR
               NEW.scored_by      IS DISTINCT FROM OLD.scored_by      OR
               NEW.scored_at      IS DISTINCT FROM OLD.scored_at
            THEN
                RAISE EXCEPTION
                    '[FIX-R8] Scoring provenance (scoring_method, scored_by, scored_at) '
                    'is frozen on response % per instrument policy (%). '
                    'Scoring metadata cannot be altered after finalization.',
                    OLD.id, v_finalization_point;
            END IF;
        END IF;

    END IF;

    -- Case B: in_progress → frozen transition is allowed.
    -- Fields may change simultaneously (submitted_at + status + score in same UPDATE).
    -- No restriction needed here — the transition itself is the legitimate write.
    -- If field data is being changed during the same transition, it is caught by
    -- rfv_update RLS (response_status = 'in_progress' in USING clause fails after
    -- the status changes to submitted within the same transaction).

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_response_lock_immutability() IS
    '[FIX-R8] Instrument-aware immutability enforcement. '
    'Reads scoring_finalization_point from form_templates to determine '
    'whether computed_score is mutable at current status transition. '
    'submission  : score frozen from submitted onward. '
    'review      : score mutable until reviewed (supervisor validation window). '
    'system_only : score always frozen for users — log_score() only. '
    'Core clinical fields (patient, version, mode, etc.) always frozen at submitted. '
    'Scoring provenance (method/scorer/time) frozen with score.';


-- =============================================================================
-- [FIX-R9] system_only scoring guard
-- =============================================================================
-- When scoring_finalization_point = 'system_only', no user can set computed_score
-- directly via INSERT or UPDATE on form_responses.
-- Score is written by log_score() SECURITY DEFINER function only.
-- This prevents RLS loopholes where a privileged user could directly set score.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_system_only_score_guard()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_finalization_point TEXT;
BEGIN
    -- Only fire if computed_score is being set or changed
    IF NEW.computed_score IS NOT DISTINCT FROM OLD.computed_score THEN
        RETURN NEW;
    END IF;
    -- On INSERT: only check if computed_score is being set
    IF TG_OP = 'INSERT' AND NEW.computed_score IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT ft.scoring_finalization_point INTO v_finalization_point
    FROM form_templates ft
    JOIN form_versions fv ON fv.form_template_id = ft.id
    WHERE fv.id = NEW.form_version_id;

    IF v_finalization_point = 'system_only' THEN
        -- Check if running as the scoring function (SECURITY DEFINER context)
        -- Application sets app.scoring_function_active = 'true' inside log_score()
        IF current_setting('app.scoring_function_active', TRUE) != 'true' THEN
            RAISE EXCEPTION
                '[FIX-R9] computed_score on response % cannot be set directly. '
                'Instrument policy = system_only. '
                'Score must be written via the log_score() system function only. '
                'Do not attempt to bypass this via direct UPDATE.',
                COALESCE(NEW.id, OLD.id);
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_system_only_score_guard
    BEFORE INSERT OR UPDATE OF computed_score
    ON form_responses
    FOR EACH ROW
    EXECUTE FUNCTION enforce_system_only_score_guard();

COMMENT ON TRIGGER trg_system_only_score_guard ON form_responses IS
    '[FIX-R9] Blocks direct computed_score writes on system_only instruments. '
    'Score may only be set via log_score() SECURITY DEFINER function, '
    'which sets app.scoring_function_active=true for its transaction. '
    'Prevents RLS loopholes where privileged users bypass scoring governance.';

-- log_score() — the ONLY permitted write path for system_only computed scores
CREATE OR REPLACE FUNCTION log_score(
    p_response_id       UUID,
    p_computed_score    NUMERIC,
    p_interpretation    TEXT DEFAULT NULL,
    p_metadata          JSONB DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_institute_id  UUID;
    v_patient_id    UUID;
BEGIN
    -- Activate the scoring guard bypass for this transaction
    PERFORM set_config('app.scoring_function_active', 'true', TRUE);  -- TRUE = local to txn

    -- Validate response exists and get context for audit
    SELECT institute_id, patient_id
    INTO v_institute_id, v_patient_id
    FROM form_responses
    WHERE id = p_response_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'log_score: form_response % not found.', p_response_id;
    END IF;

    -- Write the score
    UPDATE form_responses SET
        computed_score      = p_computed_score,
        score_interpretation = p_interpretation,
        scoring_method      = 'system_auto',
        scored_by           = NULL,
        scored_at           = NOW()
    WHERE id = p_response_id;

    -- Audit the scoring event
    PERFORM log_audit(
        v_institute_id,
        NULL,           -- actor = system
        NULL,
        'SCORE_COMPUTED',
        'form_responses',
        p_response_id,
        NULL,
        jsonb_build_object(
            'computed_score',     p_computed_score,
            'score_interpretation', p_interpretation,
            'scoring_method',     'system_auto'
        ),
        p_metadata
    );

    -- Reset guard flag (redundant with local=TRUE but explicit)
    PERFORM set_config('app.scoring_function_active', 'false', TRUE);
END;
$$;

COMMENT ON FUNCTION log_score(UUID, NUMERIC, TEXT, JSONB) IS
    '[FIX-R9] The ONLY permitted write path for system_only computed scores. '
    'Sets app.scoring_function_active=true (transaction-local) to satisfy '
    'the trg_system_only_score_guard trigger bypass check. '
    'Always writes scoring_method=system_auto and scored_by=NULL. '
    'Always writes to audit_log. '
    'SECURITY DEFINER: runs as schema owner, not caller — never grant directly to users.';


-- =============================================================================
-- PATCH R02 SUMMARY
-- =============================================================================
--
--  Fix      | What Changed
-- ──────────┼─────────────────────────────────────────────────────────────────
--  FIX-R6   | form_templates.scoring_finalization_point ADDED
--            | CHECK: submission | review | system_only
--            | Default: submission (safest posture for new instruments)
--
--  FIX-R7   | form_responses.scoring_method ADDED
--            | CHECK: system_auto | clinician_entered | supervisor_validated
--            | + chk_system_auto_no_scorer (scored_by must be NULL)
--            | + chk_human_score_requires_scorer (scored_by must be set)
--
--  FIX-R8   | enforce_response_lock_immutability() REPLACED (full rewrite)
--            | Reads scoring_finalization_point from form_templates
--            | Applies governance matrix per instrument policy
--            | Freezes scoring_method/scored_by/scored_at with computed_score
--            | Trigger condition clarified per Observation 1
--
--  FIX-R9   | enforce_system_only_score_guard() ADDED
--            | trg_system_only_score_guard on form_responses
--            | log_score() SECURITY DEFINER function added
--            | system_only scores: user writes blocked structurally
--            | Only log_score() can write system_only scores
--
-- =============================================================================
-- SCORING GOVERNANCE MATRIX — FINAL
-- =============================================================================
--
--  Status       | submission | review     | system_only
-- ──────────────┼────────────┼────────────┼────────────
--  in_progress  | editable   | editable   | log_score() only
--  submitted    | FROZEN     | editable   | log_score() only
--  reviewed     | FROZEN     | FROZEN     | log_score() only
--  locked       | FROZEN     | FROZEN     | FROZEN (all)
--
-- =============================================================================
-- FULL PHASE 2 MIGRATION SEQUENCE (final)
-- =============================================================================
--
--  1. phase1_foundation.sql
--  2. phase1_patch01.sql
--  3. phase1_patch02.sql
--  4. phase2_form_definition.sql
--  5. phase2_form_definition_patch01.sql
--  6. phase2_form_definition_patch02.sql
--  7. phase2_form_definition_patch03.sql
--  8. phase2_form_responses.sql
--  9. phase2_form_responses_patch01.sql
-- 10. phase2_form_responses_patch02.sql   ← this file
--
-- Phase 2 is now fully production-frozen.
-- Phase 3 (Clinical Core) entry conditions:
--   → Replace validate_response_context_ref() to unblock session + evaluation
--   → Replace validate_case_role_scope_ref_partial() to unblock program scope
--   → Add supersedes_response_id to form_responses (amendment workflow)
--   → therapy_type_registry, therapy_programs, session_records, evaluations,
--     milestones, case_conferences
-- =============================================================================