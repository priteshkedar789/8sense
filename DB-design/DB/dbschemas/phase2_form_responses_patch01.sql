-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 2 — FORM RESPONSE PATCH 01: LIFECYCLE ENFORCEMENT
-- =============================================================================
-- Apply after: phase2_form_responses.sql
-- =============================================================================
--
-- LOCKED CLINICAL GOVERNANCE DECISION
-- ─────────────────────────────────────────────────────────────────────────────
-- Field value edits permitted ONLY when response_status = 'in_progress'.
-- Submission is a clinical attestation event. Once submitted, the record is
-- part of the clinical record. No role — clinician, supervisor, admin — may
-- modify field values on submitted, reviewed, or locked responses.
--
-- Correction workflow (not implemented here — Phase 3 amendment table):
--   Supervisor marks response as 'requires_amendment'
--   System creates new response with supersedes_response_id reference
--   Clinician re-enters corrected data on the new response
--   Original remains permanently immutable
--
-- ─────────────────────────────────────────────────────────────────────────────
-- CORRECTIONS IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-R1]  enforce_response_lock_immutability() — immutability boundary moved
--           from 'locked' to 'submitted'. Locking remains as administrative
--           finalisation, but field edits close at submission.
--
-- [FIX-R2]  fr_update RLS policy — restrict to in_progress responses only.
--           Previously too broad (allowed UPDATE on submitted responses).
--
-- [FIX-R3]  rfv_update RLS policy — add missing UPDATE policy.
--           Without this, clinicians could INSERT field values but not correct
--           them during in_progress. Broken workflow.
--
-- [FIX-R4]  trg_rfv_lock_guard — add FOR UPDATE lock on status read.
--           Closes the concurrency race between concurrent lock transition
--           and field value INSERT. Serializes modifications on same response.
--
-- [FIX-R5]  idx_fr_template_patient — analytics index for instrument queries.
--           "All CARS-2 scores for this patient" now hits index directly.
-- =============================================================================


-- =============================================================================
-- [FIX-R1] Move immutability boundary from 'locked' → 'submitted'
-- =============================================================================
-- Previous trigger only blocked edits on locked responses.
-- Medico-legal requirement: submitted = clinical attestation = immutable.
-- New boundary: in_progress is the only mutable state for field data.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_response_lock_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- [FIX-R1] Immutability boundary is now 'submitted', not 'locked'.
    -- Once submitted_at is set, the clinical record exists.
    -- Locking is administrative finalisation — not the freeze point.
    IF OLD.response_status IN ('submitted', 'reviewed', 'locked') THEN

        -- What is never permitted after submission:
        IF NEW.form_version_id        != OLD.form_version_id             OR
           NEW.patient_id             IS DISTINCT FROM OLD.patient_id    OR
           NEW.context_ref_id         IS DISTINCT FROM OLD.context_ref_id OR
           NEW.context_type_id        != OLD.context_type_id             OR
           NEW.response_mode          != OLD.response_mode               OR
           NEW.started_at             != OLD.started_at                  OR
           NEW.submitted_at           IS DISTINCT FROM OLD.submitted_at  OR
           NEW.administered_by        IS DISTINCT FROM OLD.administered_by OR
           NEW.administration_mode    IS DISTINCT FROM OLD.administration_mode OR
           NEW.computed_score         IS DISTINCT FROM OLD.computed_score
        THEN
            RAISE EXCEPTION
                '[FIX-R1] form_response % has status=% and is clinically immutable. '
                'Clinical field values are frozen at submission. '
                'To correct data, use the amendment workflow: create a new response '
                'referencing this one via supersedes_response_id (Phase 3). '
                'Original records are never modified after submission.',
                OLD.id, OLD.response_status;
        END IF;

        -- What IS permitted after submission (administrative completion):
        -- reviewed_at, reviewed_by, locked_at, locked_by, response_status transitions,
        -- score_interpretation (narrative), scored_at, scored_by
        -- These are additive — they do not alter original clinical data.
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_response_lock_immutability() IS
    '[FIX-R1] Immutability boundary: submitted (not locked). '
    'submitted_at set = clinical attestation = core fields frozen. '
    'Permitted post-submission: reviewed_at/by, locked_at/by, status transitions, '
    'score_interpretation, scored_at/by (these are additive, not corrective). '
    'Corrections require amendment workflow — new response with supersedes_response_id.';


-- =============================================================================
-- [FIX-R2] fr_update RLS — restrict to in_progress responses only
-- =============================================================================
-- Previous policy allowed UPDATE on any response the provider was assigned to.
-- Must be narrowed: only in_progress responses are editable.
-- =============================================================================

-- Drop the previous policy and replace it
DROP POLICY IF EXISTS fr_update ON form_responses;

CREATE POLICY fr_update ON form_responses
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND response_status = 'in_progress'   -- [FIX-R2] freeze at submission
        AND (
            patient_id IS NULL
            OR current_user_assigned_to_patient(patient_id)
        )
        AND current_user_has_permission('CAN_COLLECT_RESPONSES')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND response_status = 'in_progress'
        AND (
            patient_id IS NULL
            OR current_user_assigned_to_patient(patient_id)
        )
        AND current_user_has_permission('CAN_COLLECT_RESPONSES')
    );

COMMENT ON POLICY fr_update ON form_responses IS
    '[FIX-R2] Only in_progress responses may be updated by clinicians. '
    'Submitted/reviewed/locked: update blocked by RLS + trigger (two layers). '
    'Supervisor review (reviewed_at/by) and locking (locked_at/by) are handled '
    'by separate permissions: CAN_REVIEW_RESPONSES, CAN_LOCK_RESPONSES.';

-- Supervisor review policy: allows setting reviewed_at/by on submitted responses
-- Does NOT allow field value changes (trigger enforces that separately)
CREATE POLICY fr_supervisor_review ON form_responses
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND response_status = 'submitted'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_REVIEW_RESPONSES')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND response_status IN ('submitted', 'reviewed')  -- can advance status
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_REVIEW_RESPONSES')
    );

COMMENT ON POLICY fr_supervisor_review ON form_responses IS
    'Supervisors may advance status from submitted → reviewed, set reviewed_at/by. '
    'Field value immutability (FIX-R1 trigger) independently blocks any field changes. '
    'This policy controls who can transition status — not what they can change.';

-- Locking policy: finalise reviewed responses
CREATE POLICY fr_lock ON form_responses
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND response_status = 'reviewed'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_LOCK_RESPONSES')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND response_status IN ('reviewed', 'locked')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_LOCK_RESPONSES')
    );


-- =============================================================================
-- [FIX-R3] rfv_update RLS — add missing UPDATE policy
-- =============================================================================
-- Previously INSERT was defined but no UPDATE policy existed.
-- Clinicians could not correct answers on in_progress responses.
-- =============================================================================

CREATE POLICY rfv_update ON response_field_values
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_COLLECT_RESPONSES')
        AND EXISTS (
            SELECT 1 FROM form_responses fr
            WHERE fr.id             = response_field_values.response_id
              AND fr.response_status = 'in_progress'   -- [FIX-R3] only drafts editable
              AND (
                  fr.patient_id IS NULL
                  OR current_user_assigned_to_patient(fr.patient_id)
              )
        )
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_COLLECT_RESPONSES')
        AND EXISTS (
            SELECT 1 FROM form_responses fr
            WHERE fr.id             = response_field_values.response_id
              AND fr.response_status = 'in_progress'
              AND (
                  fr.patient_id IS NULL
                  OR current_user_assigned_to_patient(fr.patient_id)
              )
        )
    );

COMMENT ON POLICY rfv_update ON response_field_values IS
    '[FIX-R3] Clinicians may update field values only on in_progress responses. '
    'Submitted/reviewed/locked responses: update blocked here by RLS '
    'AND independently by trg_rfv_lock_guard trigger. Two layers. '
    'This closes the workflow gap where INSERT was possible but UPDATE was not.';

-- rfv DELETE — also scope to in_progress (allow clearing a field answer)
CREATE POLICY rfv_delete ON response_field_values
    FOR DELETE
    USING (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_COLLECT_RESPONSES')
        AND EXISTS (
            SELECT 1 FROM form_responses fr
            WHERE fr.id             = response_field_values.response_id
              AND fr.response_status = 'in_progress'
              AND (
                  fr.patient_id IS NULL
                  OR current_user_assigned_to_patient(fr.patient_id)
              )
        )
    );

COMMENT ON POLICY rfv_delete ON response_field_values IS
    'Allows removing a field value row during in_progress (e.g. clearing a skipped flag). '
    'trg_rfv_lock_guard independently blocks DELETE on any non-in_progress response.';


-- =============================================================================
-- [FIX-R4] trg_rfv_lock_guard — add FOR UPDATE on status read
-- =============================================================================
-- Race condition: Session B reads status='in_progress', Session A locks response,
-- B inserts field row. Under READ COMMITTED, B may not see A's uncommitted status.
-- Fix: acquire FOR UPDATE lock on response row before reading status.
-- This serializes all concurrent modifications on the same response.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_field_value_response_lock()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    -- [FIX-R4] FOR UPDATE serializes concurrent status transitions and field writes.
    -- Session attempting to lock response and session inserting field value
    -- cannot run simultaneously for the same response_id.
    SELECT response_status INTO v_status
    FROM form_responses
    WHERE id = COALESCE(NEW.response_id, OLD.response_id)
    FOR UPDATE;

    -- [FIX-R1] Immutability boundary is 'submitted', not 'locked'
    IF v_status IN ('submitted', 'reviewed', 'locked') THEN
        RAISE EXCEPTION
            '[FIX-R4] form_response % has status=% — field values are immutable. '
            'Field values may only be modified while response_status = in_progress. '
            'To correct submitted data, use the amendment workflow.',
            COALESCE(NEW.response_id, OLD.response_id), v_status;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION enforce_field_value_response_lock() IS
    '[FIX-R4] FOR UPDATE lock serializes concurrent status transition and field writes. '
    'Prevents race: Session A locks response while Session B is mid-insert of field value. '
    '[FIX-R1] Immutability now enforced from submitted status, not locked. '
    'Triggers on INSERT, UPDATE, DELETE of response_field_values.';


-- =============================================================================
-- [FIX-R5] Analytics index — instrument-specific patient queries
-- =============================================================================
-- Common research/clinical query: "Show all CARS-2 scores for this patient"
-- Current path: template lookup → version JOIN → response JOIN → heavy
-- This index covers that query directly on locked (finalised) clinical responses.
-- =============================================================================

CREATE INDEX idx_fr_template_patient
    ON form_responses(form_template_id, patient_id)
    WHERE response_status = 'locked';

COMMENT ON INDEX idx_fr_template_patient IS
    '[FIX-R5] Optimizes: "all finalised responses for instrument X for patient Y". '
    'Covers the most common clinical history query pattern. '
    'Partial index on locked only — research on finalised data, not drafts.';

-- Companion index for longitudinal scoring queries
CREATE INDEX idx_fr_template_score
    ON form_responses(form_template_id, patient_id, submitted_at DESC)
    WHERE response_status = 'locked'
      AND is_scored_form = TRUE
      AND computed_score IS NOT NULL;

COMMENT ON INDEX idx_fr_template_score IS
    'Optimizes longitudinal score queries: "CARS-2 score trend for patient over time". '
    'Covers instrument + patient + time + score in one index scan. '
    'Partial: finalised, scored responses only.';


-- =============================================================================
-- LIFECYCLE ENFORCEMENT SUMMARY
-- =============================================================================
--
-- Status          | Clinician edit? | Supervisor edit? | Field values?
-- ────────────────┼─────────────────┼──────────────────┼──────────────
-- in_progress     | ✅ Yes          | ❌ No            | ✅ Mutable
-- submitted       | ❌ No           | ❌ No (annotate) | ❌ Frozen
-- reviewed        | ❌ No           | ❌ No            | ❌ Frozen
-- locked          | ❌ No           | ❌ No            | ❌ Frozen
--
-- Enforcement layers (all independent — any one would protect):
--   1. fr_update RLS       — blocks UPDATE on non-in_progress responses (header)
--   2. rfv_update RLS      — blocks UPDATE on non-in_progress field values
--   3. trg_form_response_lock_immutability — blocks field changes post-submission
--   4. trg_rfv_lock_guard  — blocks field value writes post-submission (with FOR UPDATE)
--
-- Correction path (Phase 3):
--   New response with supersedes_response_id → original unchanged forever.
--
-- =============================================================================
-- PATCH R01 SUMMARY
-- =============================================================================
--
--  Fix      | What Changed
-- ──────────┼─────────────────────────────────────────────────────────────────
--  FIX-R1   | enforce_response_lock_immutability() REPLACED
--            | Immutability boundary: submitted (not locked)
--            | Additive post-submission fields still permitted
--
--  FIX-R2   | fr_update policy REPLACED (in_progress only)
--            | fr_supervisor_review policy ADDED
--            | fr_lock policy ADDED
--
--  FIX-R3   | rfv_update policy ADDED (in_progress only)
--            | rfv_delete policy ADDED (in_progress only)
--
--  FIX-R4   | enforce_field_value_response_lock() REPLACED
--            | FOR UPDATE on response row read
--            | Immutability boundary updated to match FIX-R1
--
--  FIX-R5   | idx_fr_template_patient ADDED (locked responses)
--            | idx_fr_template_score ADDED (locked + scored)
--
-- =============================================================================
-- PHASE 2 FORM ENGINE — FINAL STATUS
-- =============================================================================
--
--  Guarantee                              | Enforcement
-- ────────────────────────────────────────┼───────────────────────────────────
--  Field meaning frozen at capture        | Composite FK (field_id, version_id)
--  Published version required             | Trigger
--  Clinical data frozen at submission     | Trigger (×2) + RLS (×2)
--  Concurrent lock race eliminated        | FOR UPDATE in trigger
--  Correct value column enforced          | Trigger + CHECK
--  Exactly one value column               | CHECK constraint
--  Locked response header immutable       | Trigger
--  In-progress edits allowed              | RLS UPDATE policies
--  Supervisor review: annotate only       | Policy design + trigger
--  Amendment via new response (Phase 3)   | Documented, not yet implemented
--  Institute isolation                    | Composite FKs throughout
--  Provider-anchored RLS                  | patient_provider_assignments
--  Research/DPDP export path              | Normalized rows + views
--  Analytics performance                  | Partial indexes on locked responses
--
-- Phase 2 is production-frozen.
-- Phase 3 (Clinical Core) may now begin.
-- =============================================================================
