-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 3 — SESSION RECORDS
-- =============================================================================
-- Apply after: phase3_clinical_core_foundation.sql + patch01
-- =============================================================================
--
-- ENTRY OBLIGATION [O1] COMPLETED IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- validate_response_context_ref() replaced with full validation.
-- session_records table now exists — session context type unblocked.
-- evaluations context remains blocked until phase3_evaluations.sql.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- DUAL-DOMAIN FREEZE ARCHITECTURE
-- ─────────────────────────────────────────────────────────────────────────────
-- A session record carries two structurally distinct classes of data:
--
-- DOMAIN A — Event Facts (what happened, when, with whom)
--   Fields: patient_id, provider_id, branch_id, department_id,
--           therapy_program_id, therapy_type_id,
--           scheduled_start, actual_start, actual_end, duration_minutes,
--           modality, attendance_status, cancellation_reason
--   Freeze: status = 'completed'
--   Rationale: The session occurred. These are historical facts.
--              Billing, payroll, attendance reporting depend on them.
--              Cannot change retroactively any more than an event can un-happen.
--
-- DOMAIN B — Clinical Documentation (what was observed, planned, recorded)
--   Fields: session_notes, goals_addressed, progress_observations,
--           risk_flags, plan_next_steps, barriers_noted,
--           session_rating, parent_feedback, structured outcome fields
--   Freeze: note_status = 'submitted'
--   Rationale: Clinical attestation. "This is what I observed and recorded."
--              Mirrors form_responses submission semantics exactly.
--
-- ABSOLUTE FREEZE
--   note_status = 'locked'
--   Everything frozen. No writes of any kind.
--   Same semantics as form_responses.response_status = 'locked'.
--
-- GOVERNANCE MATRIX:
--   status/note_status        | Domain A (facts) | Domain B (notes)
--   ─────────────────────────────────────────────────────────────
--   scheduled/in_progress     | mutable          | mutable
--   completed + draft         | FROZEN           | mutable
--   completed + submitted     | FROZEN           | FROZEN
--   completed + reviewed      | FROZEN           | FROZEN
--   completed + locked        | FROZEN           | FROZEN (absolute)
--
-- SCORING: No independent scoring governance layer.
--   session_rating is a simple numeric field (e.g. 1–5).
--   Freezes with Domain B at note submission.
--   Composite scores are derived from form_responses attached to sessions.
--
-- VERSIONING: No session_versions table.
--   Sessions are historical event instances, not reusable templates.
--   Amendment: supersedes_session_id (same model as form_responses).
-- =============================================================================


-- =============================================================================
-- SECTION 1 — SESSION RECORDS
-- =============================================================================

CREATE TABLE session_records (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    branch_id           UUID            NOT NULL REFERENCES branches(id),
    department_id       UUID            REFERENCES departments(id),

    -- Domain A: Event identity
    patient_id          UUID            NOT NULL REFERENCES patients(id),
    provider_id         UUID            NOT NULL,   -- user_institute_memberships.user_id
    therapy_program_id  UUID            REFERENCES therapy_programs(id),
    therapy_type_id     UUID            NOT NULL REFERENCES therapy_type_registry(id),

    -- Domain A: Scheduling vs actuals
    scheduled_start     TIMESTAMPTZ     NOT NULL,
    scheduled_end       TIMESTAMPTZ     NOT NULL,
    actual_start        TIMESTAMPTZ,
    actual_end          TIMESTAMPTZ,
    duration_minutes    INTEGER,        -- computed or entered; frozen at completion

    -- Domain A: Delivery facts
    modality            TEXT            NOT NULL DEFAULT 'in_person',
        -- 'in_person', 'tele', 'home_visit', 'school_visit', 'community'
    attendance_status   TEXT            NOT NULL DEFAULT 'scheduled',
        -- 'scheduled', 'attended', 'cancelled_provider', 'cancelled_patient',
        -- 'no_show', 'partial'
    cancellation_reason TEXT,
    session_number      INTEGER,        -- sequential within this program (informational)

    -- Session status lifecycle (Domain A freeze trigger)
    status              TEXT            NOT NULL DEFAULT 'scheduled',
        -- 'scheduled' → 'in_progress' → 'completed' | 'cancelled'

    -- Domain B: Clinical documentation
    session_notes       TEXT,
    goals_addressed     JSONB,
        -- [{"goal_id": "uuid", "progress": "progressing", "notes": "..."}]
    progress_observations TEXT,
    barriers_noted      TEXT,
    risk_flags          TEXT,
    plan_next_steps     TEXT,
    parent_carer_feedback TEXT,

    -- Domain B: Simple session outcome (no separate scoring governance)
    session_rating      NUMERIC(3,1),   -- e.g. 1.0–5.0; freezes with Domain B
    session_rating_notes TEXT,

    -- Note lifecycle (Domain B freeze trigger)
    note_status         TEXT            NOT NULL DEFAULT 'draft',
        -- 'draft' → 'submitted' → 'reviewed' → 'locked'

    -- Timestamps
    note_submitted_at   TIMESTAMPTZ,
    note_reviewed_at    TIMESTAMPTZ,
    note_reviewed_by    UUID            REFERENCES users(id),
    note_locked_at      TIMESTAMPTZ,
    note_locked_by      UUID            REFERENCES users(id),

    -- Amendment chain
    supersedes_session_id UUID          REFERENCES session_records(id),

    -- Provenance
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- ── Composite institute boundary FKs ─────────────────────────────────────
    CONSTRAINT fk_sr_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_sr_branch_institute
        FOREIGN KEY (branch_id, institute_id)
        REFERENCES branches(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_sr_provider_institute
        FOREIGN KEY (provider_id, institute_id)
        REFERENCES user_institute_memberships(user_id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_sr_program_institute
        FOREIGN KEY (therapy_program_id, institute_id)
        REFERENCES therapy_programs(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- ── Structural constraints ────────────────────────────────────────────────
    CONSTRAINT chk_sr_no_self_supersede
        CHECK (supersedes_session_id IS NULL OR supersedes_session_id != id),

    CONSTRAINT chk_sr_scheduled_order
        CHECK (scheduled_end > scheduled_start),

    CONSTRAINT chk_sr_actual_order
        CHECK (actual_end IS NULL OR actual_start IS NULL OR actual_end >= actual_start),

    CONSTRAINT chk_sr_duration_positive
        CHECK (duration_minutes IS NULL OR duration_minutes > 0),

    CONSTRAINT chk_sr_session_rating_range
        CHECK (session_rating IS NULL OR (session_rating >= 1.0 AND session_rating <= 5.0)),

    CONSTRAINT chk_sr_locked_implies_completed
        CHECK (note_status != 'locked' OR status = 'completed'),

    CONSTRAINT chk_sr_note_submitted_at
        CHECK (note_status = 'draft' OR note_submitted_at IS NOT NULL),

    -- Enable composite FKs from downstream tables
    CONSTRAINT uq_sr_id_institute UNIQUE (id, institute_id)
);

COMMENT ON TABLE session_records IS
    'Clinical therapy session event record. '
    'DUAL-DOMAIN FREEZE: Domain A (event facts) frozen at status=completed. '
    'Domain B (clinical notes) frozen at note_status=submitted. '
    'Both frozen absolutely at note_status=locked. '
    'No separate scoring governance — session_rating freezes with Domain B. '
    'Composite outcome scores via form_responses attached with context_type=session. '
    'Amendment via supersedes_session_id — chain model (one child per original).';

COMMENT ON COLUMN session_records.goals_addressed IS
    'Structured JSON referencing program_goals.id entries addressed in this session. '
    'Structure: [{"goal_id": "uuid", "progress": "progressing|achieved|regressing|plateau", '
    '"notes": "..."}]. '
    'Not validated as FK here — program_goals are soft-referenced by design '
    'to allow session notes to reference goals even if goal status has since changed.';

COMMENT ON COLUMN session_records.note_status IS
    'Domain B lifecycle: draft → submitted → reviewed → locked. '
    'submitted = clinical attestation of documentation. '
    'Domain B fields (notes, observations, rating) frozen at submitted. '
    'reviewed/locked = supervisory and administrative completion.';

-- Indexes
CREATE INDEX idx_sr_institute         ON session_records(institute_id);
CREATE INDEX idx_sr_patient           ON session_records(patient_id);
CREATE INDEX idx_sr_provider          ON session_records(provider_id);
CREATE INDEX idx_sr_program           ON session_records(therapy_program_id);
CREATE INDEX idx_sr_branch            ON session_records(branch_id);
CREATE INDEX idx_sr_status            ON session_records(institute_id, status);
CREATE INDEX idx_sr_note_status       ON session_records(institute_id, note_status);
CREATE INDEX idx_sr_scheduled         ON session_records(patient_id, scheduled_start DESC);
CREATE INDEX idx_sr_completed_locked  ON session_records(patient_id, actual_start DESC)
    WHERE status = 'completed' AND note_status = 'locked';
CREATE INDEX idx_sr_supersedes        ON session_records(supersedes_session_id)
    WHERE supersedes_session_id IS NOT NULL;
CREATE INDEX idx_sr_type_patient      ON session_records(therapy_type_id, patient_id)
    WHERE status = 'completed';

-- Chain amendment: one amendment per original session (mirror of form_responses)
CREATE UNIQUE INDEX uq_sr_single_amendment
    ON session_records(supersedes_session_id)
    WHERE supersedes_session_id IS NOT NULL;

COMMENT ON INDEX uq_sr_single_amendment IS
    'Enforces linear amendment chain. '
    'One original session → one child amendment. '
    'Second correction must amend the amendment, not the original. '
    'Mirrors uq_fr_single_amendment on form_responses.';


-- =============================================================================
-- SECTION 2 — DUAL-DOMAIN FREEZE TRIGGERS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Trigger A: Domain A freeze — event facts immutable at status='completed'
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_session_event_fact_freeze()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Domain A is frozen once status reaches completed or cancelled
    -- (cancelled sessions still have immutable scheduling facts)
    IF OLD.status IN ('completed', 'cancelled') THEN
        IF NEW.patient_id           IS DISTINCT FROM OLD.patient_id           OR
           NEW.provider_id          IS DISTINCT FROM OLD.provider_id          OR
           NEW.institute_id         != OLD.institute_id                        OR
           NEW.branch_id            IS DISTINCT FROM OLD.branch_id            OR
           NEW.department_id        IS DISTINCT FROM OLD.department_id        OR
           NEW.therapy_program_id   IS DISTINCT FROM OLD.therapy_program_id   OR
           NEW.therapy_type_id      IS DISTINCT FROM OLD.therapy_type_id      OR
           NEW.scheduled_start      != OLD.scheduled_start                    OR
           NEW.scheduled_end        != OLD.scheduled_end                      OR
           NEW.actual_start         IS DISTINCT FROM OLD.actual_start         OR
           NEW.actual_end           IS DISTINCT FROM OLD.actual_end           OR
           NEW.duration_minutes     IS DISTINCT FROM OLD.duration_minutes     OR
           NEW.modality             != OLD.modality                           OR
           NEW.attendance_status    != OLD.attendance_status                  OR
           NEW.cancellation_reason  IS DISTINCT FROM OLD.cancellation_reason
        THEN
            RAISE EXCEPTION
                '[Domain A] session_record % has status=% — event facts are frozen. '
                'patient, provider, branch, department, program, type, '
                'scheduled/actual times, duration, modality, and attendance '
                'cannot change after session completion. '
                'Use amendment workflow (supersedes_session_id) for corrections.',
                OLD.id, OLD.status;
        END IF;

        -- Completed sessions cannot be un-completed
        IF OLD.status = 'completed' AND NEW.status NOT IN ('completed') THEN
            RAISE EXCEPTION
                'session_record % is completed and cannot transition to status=%. '
                'Completed sessions are permanent events. '
                'Create an amendment if the session facts were recorded incorrectly.',
                OLD.id, NEW.status;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_session_event_fact_freeze
    BEFORE UPDATE ON session_records
    FOR EACH ROW
    EXECUTE FUNCTION enforce_session_event_fact_freeze();

COMMENT ON TRIGGER trg_session_event_fact_freeze ON session_records IS
    '[Domain A] Freezes event identity and scheduling facts at status=completed. '
    'Event facts include: patient, provider, branch, dept, program, type, '
    'all time fields, modality, attendance. '
    'Cancelled sessions also freeze event facts — the non-attendance is a fact. '
    'Completed sessions cannot revert to earlier status.';

-- ---------------------------------------------------------------------------
-- Trigger B: Domain B freeze — clinical notes immutable at note_status='submitted'
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_session_note_freeze()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.note_status IN ('submitted', 'reviewed', 'locked') THEN
        IF NEW.session_notes         IS DISTINCT FROM OLD.session_notes         OR
           NEW.goals_addressed       IS DISTINCT FROM OLD.goals_addressed       OR
           NEW.progress_observations IS DISTINCT FROM OLD.progress_observations OR
           NEW.barriers_noted        IS DISTINCT FROM OLD.barriers_noted        OR
           NEW.risk_flags            IS DISTINCT FROM OLD.risk_flags            OR
           NEW.plan_next_steps       IS DISTINCT FROM OLD.plan_next_steps       OR
           NEW.parent_carer_feedback IS DISTINCT FROM OLD.parent_carer_feedback OR
           NEW.session_rating        IS DISTINCT FROM OLD.session_rating        OR
           NEW.session_rating_notes  IS DISTINCT FROM OLD.session_rating_notes
        THEN
            RAISE EXCEPTION
                '[Domain B] session_record % note_status=% — clinical documentation '
                'is frozen at submission. session_notes, goals_addressed, '
                'progress_observations, risk_flags, plan_next_steps, '
                'and session_rating cannot change after note submission. '
                'Use amendment workflow (supersedes_session_id) to correct submitted notes.',
                OLD.id, OLD.note_status;
        END IF;
    END IF;

    -- Once locked: block all status-transition writes too (absolute freeze)
    IF OLD.note_status = 'locked' THEN
        IF NEW.note_status IS DISTINCT FROM OLD.note_status THEN
            RAISE EXCEPTION
                'session_record % note is locked (absolutely final). '
                'note_status cannot change from locked. '
                'Create an amendment session to supersede this record.',
                OLD.id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_session_note_freeze
    BEFORE UPDATE ON session_records
    FOR EACH ROW
    EXECUTE FUNCTION enforce_session_note_freeze();

COMMENT ON TRIGGER trg_session_note_freeze ON session_records IS
    '[Domain B] Freezes clinical documentation at note_status=submitted. '
    'Clinical documentation: notes, goals, observations, risk flags, '
    'next steps, feedback, session_rating. '
    'session_rating freezes here (not with Domain A) because it is a '
    'clinical observation, not a scheduling fact. '
    'Locked note: absolute final state — no further status transitions.';

-- ---------------------------------------------------------------------------
-- Trigger C: Amendment integrity
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_session_amendment_integrity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_original_status       TEXT;
    v_original_note_status  TEXT;
    v_original_inst         UUID;
BEGIN
    IF NEW.supersedes_session_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT status, note_status, institute_id
    INTO v_original_status, v_original_note_status, v_original_inst
    FROM session_records
    WHERE id = NEW.supersedes_session_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Session amendment error: original session % not found.',
            NEW.supersedes_session_id;
    END IF;

    IF v_original_inst != NEW.institute_id THEN
        RAISE EXCEPTION
            'Session amendment error: original session % belongs to a different institute.',
            NEW.supersedes_session_id;
    END IF;

    -- Meaningful amendment: original should be completed with submitted/reviewed/locked note
    IF v_original_status != 'completed' OR
       v_original_note_status NOT IN ('submitted', 'reviewed', 'locked')
    THEN
        RAISE EXCEPTION
            'Session amendment error: original session % has status=%, note_status=%. '
            'Amendments are only created for completed sessions with submitted notes. '
            'For in-progress sessions, edit the original directly.',
            NEW.supersedes_session_id, v_original_status, v_original_note_status;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_session_amendment_integrity
    BEFORE INSERT OR UPDATE OF supersedes_session_id
    ON session_records
    FOR EACH ROW
    EXECUTE FUNCTION enforce_session_amendment_integrity();

-- ---------------------------------------------------------------------------
-- Trigger D: provider active membership validation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_session_provider_active_membership()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_membership_status TEXT;
    v_is_active         BOOLEAN;
BEGIN
    -- Only validate on active sessions (allow amending historical records)
    IF NEW.status NOT IN ('scheduled', 'in_progress') THEN
        RETURN NEW;
    END IF;

    SELECT membership_status, is_active
    INTO v_membership_status, v_is_active
    FROM user_institute_memberships
    WHERE user_id    = NEW.provider_id
      AND institute_id = NEW.institute_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'session_record: provider % is not a member of institute %.',
            NEW.provider_id, NEW.institute_id;
    END IF;

    IF v_membership_status != 'active' OR v_is_active = FALSE THEN
        RAISE EXCEPTION
            'session_record: provider % membership in institute % is not active '
            '(status=%, is_active=%). Active membership required for new sessions.',
            NEW.provider_id, NEW.institute_id, v_membership_status, v_is_active;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_session_provider_membership
    BEFORE INSERT OR UPDATE OF provider_id, institute_id, status
    ON session_records
    FOR EACH ROW
    EXECUTE FUNCTION enforce_session_provider_active_membership();


-- =============================================================================
-- SECTION 3 — SESSION FORM RESPONSE LINKS
-- =============================================================================
-- Form responses attached to a session (context_type='session').
-- Thin junction: form_responses.context_ref_id already points to session_records.id.
-- This view makes session ↔ response navigation explicit.
-- =============================================================================

CREATE VIEW v_session_form_responses AS
SELECT
    sr.id                   AS session_id,
    sr.institute_id,
    sr.patient_id,
    sr.provider_id,
    sr.therapy_type_id,
    sr.status               AS session_status,
    sr.note_status,
    fr.id                   AS response_id,
    fr.form_template_id,
    fr.form_version_id,
    fr.response_mode,
    fr.response_status,
    fr.computed_score,
    fr.submitted_at
FROM session_records sr
JOIN form_responses fr
    ON fr.context_ref_id = sr.id
    AND fr.institute_id  = sr.institute_id
WHERE fr.context_type_id = (
    SELECT id FROM response_context_types WHERE code = 'session'
);

COMMENT ON VIEW v_session_form_responses IS
    'Navigation view: all form responses attached to each session. '
    'Use for: session outcome reporting, goal progress tracking via instruments, '
    'composite scoring across session-attached evaluations. '
    'RLS on underlying tables applies.';


-- =============================================================================
-- SECTION 4 — RLS
-- =============================================================================
-- Provider-anchored to patient_provider_assignments.
-- Supervisors see all sessions in their institute scope.
-- Providers see only sessions for their assigned patients.
-- =============================================================================

ALTER TABLE session_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE session_records FORCE ROW LEVEL SECURITY;

CREATE POLICY sr_platform_admin ON session_records
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY sr_read ON session_records
    FOR SELECT USING (
        institute_id = current_institute_id()
        AND (
            current_user_has_institute_scope()
            OR current_user_assigned_to_patient(patient_id)
            OR provider_id = current_user_id()   -- provider sees own sessions
        )
    );

CREATE POLICY sr_insert ON session_records
    FOR INSERT WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
        AND current_user_assigned_to_patient(patient_id)
    );

-- Clinician update: only scheduled/in_progress sessions
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
    );

-- Note submission update: clinician moves note_status to submitted
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
    );

-- Supervisor note review
CREATE POLICY sr_note_review ON session_records
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND note_status = 'submitted'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_REVIEW_SESSIONS')
    );

-- Supervisor note lock
CREATE POLICY sr_note_lock ON session_records
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND note_status = 'reviewed'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_LOCK_SESSIONS')
    );

-- Deletion: only scheduled sessions not yet started
CREATE POLICY sr_delete ON session_records
    FOR DELETE
    USING (
        institute_id = current_institute_id()
        AND status = 'scheduled'
        AND actual_start IS NULL
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
        AND current_user_has_institute_scope()
    );


-- =============================================================================
-- SECTION 5 — [O1] Replace validate_response_context_ref()
-- =============================================================================
-- Entry obligation [O1]: session_records now exists.
-- Unblock session context type. evaluations remains blocked until next file.
-- =============================================================================

CREATE OR REPLACE FUNCTION validate_response_context_ref()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_context_code          TEXT;
    v_requires_patient      BOOLEAN;
    v_requires_context_ref  BOOLEAN;
    v_patient_id            UUID;
    v_session_inst          UUID;
BEGIN
    SELECT rct.code, rct.requires_patient_id, rct.requires_context_ref
    INTO v_context_code, v_requires_patient, v_requires_context_ref
    FROM response_context_types rct
    WHERE rct.id = NEW.context_type_id;

    -- patient_id presence
    IF v_requires_patient AND NEW.patient_id IS NULL THEN
        RAISE EXCEPTION
            'context_type=% requires patient_id to be set. response_id: %',
            v_context_code, NEW.id;
    END IF;

    -- context_type = 'patient': no context_ref_id needed
    IF v_context_code = 'patient' AND NEW.context_ref_id IS NOT NULL THEN
        RAISE EXCEPTION
            'context_type=patient does not use context_ref_id. '
            'patient_id is the context anchor. Set context_ref_id to NULL.';
    END IF;

    -- context_type = 'session': [O1] NOW UNBLOCKED — session_records exists
    IF v_context_code = 'session' THEN
        IF NEW.context_ref_id IS NULL THEN
            RAISE EXCEPTION
                'context_type=session requires context_ref_id (session_records.id). '
                'response_id: %', NEW.id;
        END IF;

        -- Validate session exists in same institute
        SELECT sr.institute_id, sr.patient_id
        INTO v_session_inst, v_patient_id
        FROM session_records sr
        WHERE sr.id = NEW.context_ref_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'context_type=session: context_ref_id % does not reference '
                'a valid session_record. response_id: %',
                NEW.context_ref_id, NEW.id;
        END IF;

        IF v_session_inst != NEW.institute_id THEN
            RAISE EXCEPTION
                'context_type=session: session % belongs to a different institute. '
                'response_id: %',
                NEW.context_ref_id, NEW.id;
        END IF;

        -- patient_id on response must match session's patient
        IF NEW.patient_id IS NOT NULL AND NEW.patient_id != v_patient_id THEN
            RAISE EXCEPTION
                'context_type=session: response patient_id % does not match '
                'session patient_id %. response_id: %',
                NEW.patient_id, v_patient_id, NEW.id;
        END IF;
    END IF;

    -- context_type = 'evaluation': still blocked until phase3_evaluations.sql
    IF v_context_code = 'evaluation' THEN
        RAISE EXCEPTION
            'context_type=evaluation is not yet supported. '
            'evaluations table will be created in phase3_evaluations.sql. '
            'Do not create evaluation-context responses until that migration runs.';
    END IF;

    -- context_type = 'research': context_ref_id optional, no FK until Phase 3 complete
    -- context_type = 'discharge': patient_id sufficient

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION validate_response_context_ref() IS
    '[O1] Phase 3 partial replacement. session context type now unblocked. '
    'session context: validates context_ref_id → session_records, '
    'checks institute boundary, checks patient_id consistency. '
    'evaluation context: still blocked until phase3_evaluations.sql. '
    'Phase 3 evaluations file MUST complete the final replacement.';


-- =============================================================================
-- SECTION 6 — ANALYTICS VIEWS
-- =============================================================================

-- Session attendance summary per patient per program
CREATE VIEW v_patient_session_summary AS
SELECT
    sr.institute_id,
    sr.patient_id,
    sr.therapy_program_id,
    sr.therapy_type_id,
    COUNT(*)                                    AS total_sessions,
    COUNT(*) FILTER (WHERE sr.attendance_status = 'attended')   AS attended,
    COUNT(*) FILTER (WHERE sr.attendance_status = 'no_show')    AS no_shows,
    COUNT(*) FILTER (WHERE sr.attendance_status LIKE 'cancelled%') AS cancelled,
    AVG(sr.duration_minutes) FILTER (
        WHERE sr.attendance_status = 'attended')                AS avg_duration_minutes,
    AVG(sr.session_rating) FILTER (
        WHERE sr.session_rating IS NOT NULL
        AND sr.note_status IN ('submitted','reviewed','locked')) AS avg_session_rating,
    MIN(sr.actual_start)                        AS first_session,
    MAX(sr.actual_start)                        AS most_recent_session
FROM session_records sr
WHERE sr.status = 'completed'
GROUP BY
    sr.institute_id, sr.patient_id,
    sr.therapy_program_id, sr.therapy_type_id;

COMMENT ON VIEW v_patient_session_summary IS
    'Attendance and engagement summary per patient per program per therapy type. '
    'Only completed sessions. avg_session_rating excludes draft notes. '
    'Use for: attendance reporting, engagement analytics, billing reconciliation.';


-- =============================================================================
-- PHASE 3 SESSION RECORDS — INVENTORY
-- =============================================================================
--
-- Entry obligation completed:
--   [O1] validate_response_context_ref() REPLACED
--        session context type now validates against session_records
--        evaluation context remains blocked until phase3_evaluations.sql
--
-- Tables:
--   session_records         dual-domain freeze, amendment chain
--
-- Views:
--   v_session_form_responses   session ↔ form response navigation
--   v_patient_session_summary  attendance and engagement analytics
--
-- Triggers:
--   trg_session_event_fact_freeze      Domain A freeze at completed
--   trg_session_note_freeze            Domain B freeze at note submitted
--   trg_session_amendment_integrity    amendment chain validation
--   trg_session_provider_membership    active membership gate
--
-- Indexes: 11 including partial on completed/locked and amendment chain
--
-- RLS: 7 policies covering read, insert, clinician update, note submit,
--      supervisor review, supervisor lock, delete (scheduled-only)
--
-- =============================================================================
-- NEXT: phase3_evaluations.sql
-- =============================================================================
-- Must complete [O1] by replacing validate_response_context_ref() one final time
-- to unblock evaluation context type.
-- Tables: evaluations, evaluation_versions, evaluation_assignments
-- =============================================================================