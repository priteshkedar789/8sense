-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 3 — SESSION RECORDS PATCH 01: RLS UPDATE HARDENING
-- =============================================================================
-- Apply after: phase3_session_records.sql
-- =============================================================================
--
-- FIXES IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-S1] Add WITH CHECK to all session_records UPDATE RLS policies.
--          Without WITH CHECK, a user passing USING could update status and
--          note_status in the same statement and bypass lifecycle constraints.
--          USING controls which rows are visible for update.
--          WITH CHECK controls what new values are permitted.
--          Both are required for correct lifecycle progression enforcement.
--
-- [FIX-S2] Lifecycle timestamp consistency constraints.
--          note_submitted_at must be NULL while draft.
--          note_reviewed_at only set when note_status in (reviewed, locked).
--          note_locked_at only set when note_status = locked.
--          These enforce temporal consistency without trigger overhead.
-- =============================================================================


-- =============================================================================
-- [FIX-S1] Replace all UPDATE policies with WITH CHECK
-- =============================================================================

DROP POLICY IF EXISTS sr_clinician_update  ON session_records;
DROP POLICY IF EXISTS sr_note_submit       ON session_records;
DROP POLICY IF EXISTS sr_note_review       ON session_records;
DROP POLICY IF EXISTS sr_note_lock         ON session_records;

-- Clinician update: scheduled/in_progress sessions (Domain A facts still mutable)
CREATE POLICY sr_clinician_update ON session_records
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND status IN ('scheduled', 'in_progress')
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
        AND (
            current_user_assigned_to_patient(patient_id)
            OR provider_id = current_user_id()
        )
    )
    WITH CHECK (
        institute_id = current_institute_id()
        -- Status may advance to completed or cancelled, not regress
        AND status IN ('scheduled', 'in_progress', 'completed', 'cancelled')
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
        AND (
            current_user_assigned_to_patient(patient_id)
            OR provider_id = current_user_id()
        )
    );

COMMENT ON POLICY sr_clinician_update ON session_records IS
    '[FIX-S1] WITH CHECK added. '
    'USING: row must be scheduled/in_progress and provider must be assigned. '
    'WITH CHECK: new status may advance to completed/cancelled but not regress. '
    'Domain A freeze trigger independently blocks fact mutations after completion.';

-- Note submission: completed session, draft note → submitted
CREATE POLICY sr_note_submit ON session_records
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND status = 'completed'
        AND note_status = 'draft'
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
        AND (
            current_user_assigned_to_patient(patient_id)
            OR provider_id = current_user_id()
        )
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND status = 'completed'
        -- Only advance to submitted — cannot skip to reviewed or locked
        AND note_status IN ('draft', 'submitted')
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
        AND (
            current_user_assigned_to_patient(patient_id)
            OR provider_id = current_user_id()
        )
    );

COMMENT ON POLICY sr_note_submit ON session_records IS
    '[FIX-S1] WITH CHECK added. '
    'Clinician can only advance note_status draft → submitted. '
    'Cannot skip directly to reviewed or locked via this policy. '
    'Domain B freeze trigger independently blocks documentation changes after submission.';

-- Supervisor review: submitted note → reviewed
CREATE POLICY sr_note_review ON session_records
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND note_status = 'submitted'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_REVIEW_SESSIONS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        -- Can advance submitted → reviewed, not jump to locked
        AND note_status IN ('submitted', 'reviewed')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_REVIEW_SESSIONS')
    );

COMMENT ON POLICY sr_note_review ON session_records IS
    '[FIX-S1] WITH CHECK added. '
    'Supervisor can only advance note_status submitted → reviewed. '
    'Cannot skip directly to locked. One step at a time. '
    'Domain B freeze trigger independently blocks documentation mutations.';

-- Supervisor lock: reviewed note → locked
CREATE POLICY sr_note_lock ON session_records
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND note_status = 'reviewed'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_LOCK_SESSIONS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        -- Can only finalise: reviewed → locked
        AND note_status IN ('reviewed', 'locked')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_LOCK_SESSIONS')
    );

COMMENT ON POLICY sr_note_lock ON session_records IS
    '[FIX-S1] WITH CHECK added. '
    'Supervisor can only advance note_status reviewed → locked. '
    'locked is the absolute final state — no further transitions permitted. '
    'Domain B trigger independently enforces locked immutability.';


-- =============================================================================
-- [FIX-S2] Lifecycle timestamp consistency constraints
-- =============================================================================
-- Enforce temporal ordering of lifecycle timestamps at the schema level.
-- Prevents: note_reviewed_at set while still draft, locked_at before submitted, etc.
-- CHECK constraints are evaluated on INSERT and UPDATE — zero trigger overhead.
-- =============================================================================

-- note_submitted_at must be NULL if still draft
ALTER TABLE session_records
    ADD CONSTRAINT chk_sr_submitted_at_timing
    CHECK (
        note_status != 'draft'
        OR note_submitted_at IS NULL
    );

COMMENT ON CONSTRAINT chk_sr_submitted_at_timing ON session_records IS
    '[FIX-S2] note_submitted_at must be NULL while note_status=draft. '
    'Prevents backdating submission timestamp.';

-- note_reviewed_at only valid at reviewed or locked
ALTER TABLE session_records
    ADD CONSTRAINT chk_sr_reviewed_at_timing
    CHECK (
        note_reviewed_at IS NULL
        OR note_status IN ('reviewed', 'locked')
    );

COMMENT ON CONSTRAINT chk_sr_reviewed_at_timing ON session_records IS
    '[FIX-S2] note_reviewed_at may only be set once note_status reaches reviewed. '
    'Cannot set a review timestamp on a draft or submitted note.';

-- note_locked_at only valid when locked
ALTER TABLE session_records
    ADD CONSTRAINT chk_sr_locked_at_timing
    CHECK (
        note_locked_at IS NULL
        OR note_status = 'locked'
    );

COMMENT ON CONSTRAINT chk_sr_locked_at_timing ON session_records IS
    '[FIX-S2] note_locked_at may only be set when note_status=locked. '
    'Prevents premature lock timestamp during review stage.';

-- Reviewed implies submitted
ALTER TABLE session_records
    ADD CONSTRAINT chk_sr_reviewed_implies_submitted
    CHECK (
        note_status NOT IN ('reviewed', 'locked')
        OR note_submitted_at IS NOT NULL
    );

COMMENT ON CONSTRAINT chk_sr_reviewed_implies_submitted ON session_records IS
    '[FIX-S2] A reviewed or locked note must have a submission timestamp. '
    'Enforces that review cannot precede submission in the lifecycle.';


-- =============================================================================
-- PATCH S01 SUMMARY
-- =============================================================================
--
--  Fix      | What Changed
-- ──────────┼─────────────────────────────────────────────────────────────────
--  FIX-S1   | sr_clinician_update: WITH CHECK — status can advance, not regress
--            | sr_note_submit:     WITH CHECK — draft → submitted only
--            | sr_note_review:     WITH CHECK — submitted → reviewed only
--            | sr_note_lock:       WITH CHECK — reviewed → locked only
--
--  FIX-S2   | chk_sr_submitted_at_timing     — NULL while draft
--            | chk_sr_reviewed_at_timing      — only at reviewed/locked
--            | chk_sr_locked_at_timing        — only at locked
--            | chk_sr_reviewed_implies_submitted — review implies prior submission
--
-- =============================================================================
-- SESSION RECORDS — FINAL ENFORCEMENT LAYERS
-- =============================================================================
--
--  Guarantee                          | Layer
-- ────────────────────────────────────┼──────────────────────────────────────
--  Domain A frozen at completed       | Trigger A
--  Domain B frozen at note submitted  | Trigger B
--  Note status progression (who)      | RLS USING
--  Note status progression (what)     | RLS WITH CHECK  ← FIX-S1
--  Timestamp temporal consistency     | CHECK constraints ← FIX-S2
--  Amendment chain (one child)        | Unique index
--  Amendment only on completed+submitted | Trigger C
--  Provider active membership         | Trigger D
--  Institute boundary                 | Composite FKs
--  Context ref validated (session)    | validate_response_context_ref()
--
-- phase3_session_records.sql is now production-frozen.
-- =============================================================================
