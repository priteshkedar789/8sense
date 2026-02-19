-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 3 — EVALUATIONS PATCH 01: STRUCTURAL HARDENING
-- =============================================================================
-- Apply after: phase3_evaluations.sql
-- =============================================================================
--
-- LOCKED DECISIONS
-- ─────────────────────────────────────────────────────────────────────────────
-- [D-E1] Lifecycle transition enforcement via trigger.
--        draft → submitted → reviewed → locked only. No skips. No reversals.
--        RLS WITH CHECK handles role-based access. Trigger handles structural order.
--        Platform admin and SECURITY DEFINER contexts must also respect lifecycle.
--
-- [D-E2] Instrument evaluation submission hard gate.
--        evaluation_type='instrument' cannot transition to submitted unless a
--        submitted form_response exists with context_type='evaluation' and
--        context_ref_id = this evaluation id.
--        A submitted instrument evaluation without form data is not clinically
--        defensible in regulatory, insurance, or DPDP audit contexts.
--
-- [D-E3] summary_score allowed on instrument evaluations.
--        summary_score is an interpretive clinical judgment layer — distinct from
--        form_responses.computed_score (the standardized instrument output).
--        Clinicians may document a Global Clinical Impression alongside the raw score.
--        Column renamed to interpretive_score for semantic clarity.
--        Both scores may coexist — neither replaces the other.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- FIXES IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-E1] enforce_evaluation_lifecycle_transitions() trigger ADDED.
--          Blocks status skips and reversals. Independent of RLS.
--
-- [FIX-E2] enforce_evaluation_clinical_report_completeness() REPLACED.
--          Extended to also enforce form_response existence check for instruments
--          on draft → submitted transition. Hard gate.
--
-- [FIX-E3] summary_score renamed to interpretive_score for semantic precision.
--          summary_score_label renamed to interpretive_score_label.
--          Column comment clarifies relationship to computed_score.
-- =============================================================================


-- =============================================================================
-- [FIX-E3] Rename summary_score → interpretive_score for semantic clarity
-- =============================================================================
-- Structural rename before other changes to avoid confusion in new triggers.
-- summary_score implies it summarises the instrument score.
-- interpretive_score makes clear it is the clinician's separate judgment.
-- =============================================================================

ALTER TABLE evaluations
    RENAME COLUMN summary_score TO interpretive_score;

ALTER TABLE evaluations
    RENAME COLUMN summary_score_label TO interpretive_score_label;

COMMENT ON COLUMN evaluations.interpretive_score IS
    '[FIX-E3] Clinician''s interpretive judgment — distinct from instrument score. '
    'For instrument evaluations: coexists with form_responses.computed_score. '
    'Example: CARS-2 computed_score=34 (form engine), '
    'interpretive_score=2.5 (Global Clinical Impression on 1-5 scale). '
    'For clinical_report evaluations: the primary holistic rating. '
    'Neither replaces the other. Both may be NULL.';

COMMENT ON COLUMN evaluations.interpretive_score_label IS
    'Narrative label for interpretive_score. '
    'Example: "Moderate", "Mild with compensatory strategies", "High Support Needs". '
    'Free text — not constrained to a lookup — because clinical language varies.';


-- =============================================================================
-- [FIX-E1] Lifecycle transition enforcement trigger
-- =============================================================================
-- Enforces valid forward-only status transitions at the structural level.
-- Runs independently of RLS — protects against platform admin or
-- SECURITY DEFINER context bypassing lifecycle order.
-- Mirrors the session governance model.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_evaluation_lifecycle_transitions()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- No change in status: pass through
    IF NEW.evaluation_status = OLD.evaluation_status THEN
        RETURN NEW;
    END IF;

    -- Enforce valid forward-only transitions
    IF OLD.evaluation_status = 'draft' AND
       NEW.evaluation_status NOT IN ('draft', 'submitted') THEN
        RAISE EXCEPTION
            '[FIX-E1] Invalid evaluation status transition: draft → %. '
            'Only draft → submitted is permitted from draft status. '
            'Cannot skip review or lock stages.',
            NEW.evaluation_status;
    END IF;

    IF OLD.evaluation_status = 'submitted' AND
       NEW.evaluation_status NOT IN ('submitted', 'reviewed') THEN
        RAISE EXCEPTION
            '[FIX-E1] Invalid evaluation status transition: submitted → %. '
            'Only submitted → reviewed is permitted. '
            'Cannot skip review or revert to draft.',
            NEW.evaluation_status;
    END IF;

    IF OLD.evaluation_status = 'reviewed' AND
       NEW.evaluation_status NOT IN ('reviewed', 'locked') THEN
        RAISE EXCEPTION
            '[FIX-E1] Invalid evaluation status transition: reviewed → %. '
            'Only reviewed → locked is permitted. '
            'Cannot skip lock or revert to earlier stage.',
            NEW.evaluation_status;
    END IF;

    IF OLD.evaluation_status = 'locked' AND
       NEW.evaluation_status != 'locked' THEN
        RAISE EXCEPTION
            '[FIX-E1] evaluation % is locked and absolutely final. '
            'Status cannot change from locked under any circumstances. '
            'Create an amendment to supersede this evaluation.',
            OLD.id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_evaluation_lifecycle_transitions
    BEFORE UPDATE OF evaluation_status
    ON evaluations
    FOR EACH ROW
    EXECUTE FUNCTION enforce_evaluation_lifecycle_transitions();

COMMENT ON TRIGGER trg_evaluation_lifecycle_transitions ON evaluations IS
    '[FIX-E1] Structural lifecycle enforcement independent of RLS. '
    'Valid transitions: draft→submitted, submitted→reviewed, reviewed→locked. '
    'All other transitions (skips and reversals) are blocked. '
    'Fires on SECURITY DEFINER contexts and platform admin — no bypass path. '
    'Mirrors trg_session_event_fact_freeze lifecycle enforcement model.';


-- =============================================================================
-- [FIX-E2] Instrument submission hard gate
-- =============================================================================
-- Replace the previous clinical completeness trigger with an extended version
-- that also enforces form_response existence for instrument evaluations.
--
-- Gate condition: on draft → submitted transition:
--   IF evaluation_type = 'instrument':
--     A submitted form_response must exist with:
--       context_type_id = 'evaluation'
--       context_ref_id  = this evaluation's id
--       response_status IN ('submitted', 'reviewed', 'locked')
--   IF evaluation_type = 'clinical_report':
--     narrative_report must be non-empty
-- =============================================================================

DROP TRIGGER IF EXISTS trg_evaluation_clinical_completeness ON evaluations;

CREATE OR REPLACE FUNCTION enforce_evaluation_submission_completeness()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_form_response_count INTEGER;
    v_eval_context_type_id UUID;
BEGIN
    -- Only run on draft → submitted transition
    IF NOT (OLD.evaluation_status = 'draft' AND NEW.evaluation_status = 'submitted') THEN
        RETURN NEW;
    END IF;

    -- Clinical report: narrative_report required
    IF NEW.evaluation_type = 'clinical_report' THEN
        IF NEW.narrative_report IS NULL OR TRIM(NEW.narrative_report) = '' THEN
            RAISE EXCEPTION
                '[FIX-E2] evaluation % (clinical_report) cannot be submitted '
                'without narrative_report content. '
                'narrative_report is required for clinical_report evaluations at submission.',
                NEW.id;
        END IF;
    END IF;

    -- Instrument evaluation: submitted form_response must exist
    IF NEW.evaluation_type = 'instrument' THEN

        -- Get the 'evaluation' context type id
        SELECT id INTO v_eval_context_type_id
        FROM response_context_types
        WHERE code = 'evaluation';

        -- Check for at least one submitted form_response linked to this evaluation
        SELECT COUNT(*) INTO v_form_response_count
        FROM form_responses fr
        WHERE fr.context_ref_id     = NEW.id
          AND fr.context_type_id    = v_eval_context_type_id
          AND fr.institute_id       = NEW.institute_id
          AND fr.response_status   IN ('submitted', 'reviewed', 'locked');

        IF v_form_response_count = 0 THEN
            RAISE EXCEPTION
                '[FIX-E2] evaluation % (instrument) cannot be submitted without '
                'a corresponding submitted form_response. '
                'At least one form_response with context_type=evaluation, '
                'context_ref_id=%, and response_status IN (submitted/reviewed/locked) '
                'must exist before this evaluation can be submitted. '
                'Clinical workflow: create evaluation (draft) → capture instrument data '
                'via form_response → submit form_response → then submit evaluation.',
                NEW.id, NEW.id;
        END IF;

    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_evaluation_submission_completeness
    BEFORE UPDATE OF evaluation_status
    ON evaluations
    FOR EACH ROW
    EXECUTE FUNCTION enforce_evaluation_submission_completeness();

COMMENT ON TRIGGER trg_evaluation_submission_completeness ON evaluations IS
    '[FIX-E2] Submission completeness gate. Fires on draft → submitted transition only. '
    'clinical_report: narrative_report must be non-empty. '
    'instrument: at least one submitted form_response must exist with '
    'context_type=evaluation and context_ref_id=this evaluation id. '
    'Hard gate — no soft window, no eventual consistency. '
    'Defensible in regulatory, insurance, and DPDP audit contexts. '
    'Workflow: draft evaluation → capture form data → submit form → submit evaluation.';


-- =============================================================================
-- ENFORCEMENT STACK — EVALUATIONS FINAL
-- =============================================================================
--
--  Layer                              | Responsibility
-- ────────────────────────────────────┼──────────────────────────────────────
--  chk_ev_instrument_requires_form    | form_version_id NOT NULL for instruments
--  chk_ev_clinical_report_no_form     | form_version_id NULL for clinical reports
--  chk_ev_type_valid                  | evaluation_type domain
--  Timestamp CHECK constraints        | Temporal ordering of lifecycle events
--  trg_evaluation_lifecycle_transitions| Valid forward-only status transitions
--  trg_evaluation_submission_completeness | Content completeness at submission
--  trg_evaluation_freeze              | All content frozen post-submission
--  trg_evaluation_amendment_integrity | Amendment chain validation
--  trg_evaluation_evaluator_membership| Active membership gate
--  RLS USING                          | Who may attempt update
--  RLS WITH CHECK                     | What new state may be written
--
-- =============================================================================
-- PATCH E01 SUMMARY
-- =============================================================================
--
--  Fix      | What Changed
-- ──────────┼─────────────────────────────────────────────────────────────────
--  FIX-E1   | enforce_evaluation_lifecycle_transitions() ADDED
--            | trg_evaluation_lifecycle_transitions trigger ADDED
--            | Structural lifecycle order enforced independent of RLS
--
--  FIX-E2   | enforce_evaluation_submission_completeness() REPLACED
--            | trg_evaluation_submission_completeness trigger REPLACED
--            | clinical_report: narrative required (unchanged)
--            | instrument: submitted form_response hard gate ADDED
--
--  FIX-E3   | summary_score → interpretive_score (renamed)
--            | summary_score_label → interpretive_score_label (renamed)
--            | Comment clarifies coexistence with computed_score
--
-- =============================================================================
-- PHASE 3 EVALUATIONS — PRODUCTION FROZEN
-- =============================================================================
--
-- All three issues identified in review are now closed:
--   Issue 1: lifecycle transition enforcement ✅ trigger added
--   Issue 2: instrument submission gate ✅ hard gate enforced
--   Issue 3: summary_score semantics ✅ renamed + clarified, allowed for all types
--
-- phase3_evaluations.sql + phase3_evaluations_patch01.sql = production-frozen
--
-- NEXT: phase3_clinical_events.sql
--   milestones, plan_change_requests, case_conferences
-- =============================================================================