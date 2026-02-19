-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 3 — EVALUATIONS
-- =============================================================================
-- Apply after: phase3_session_records.sql + patch01
-- =============================================================================
--
-- ENTRY OBLIGATION [O1] COMPLETED IN THIS FILE (FINAL)
-- ─────────────────────────────────────────────────────────────────────────────
-- validate_response_context_ref() final replacement.
-- evaluations table now exists — evaluation context type fully unblocked.
-- [O1] is closed after this file. No further replacements needed.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- EVALUATION ARCHITECTURE
-- ─────────────────────────────────────────────────────────────────────────────
-- Two evaluation types in one table:
--
-- 'instrument'       — structured assessment using a form instrument
--                      (CARS-2, ADOS-2, Vineland-3, WISC-V, etc.)
--                      form_version_id NOT NULL
--                      Scoring governed by form engine (scoring_finalization_point)
--                      Field-level data in response_field_values via form_responses
--
-- 'clinical_report'  — narrative clinical evaluation (no form instrument)
--                      (Developmental assessment, MDT report, school readiness)
--                      form_version_id NULL
--                      narrative_report TEXT carries content
--                      Freezes at note submission (mirrors session Domain B)
--
-- CONDITIONAL INTEGRITY:
--   instrument     → form_version_id NOT NULL, narrative_report optional
--   clinical_report → form_version_id NULL, narrative_report NOT NULL at submission
--
-- VERSIONING:
--   Linear version snapshots via evaluation_versions (append-only).
--   Not branchable — evaluations are patient-specific events, not templates.
--   Mirrors therapy_program_versions, not form_versions.
--
-- FREEZE MODEL:
--   Both types: freeze at evaluation_status = 'submitted'
--   Absolute freeze at evaluation_status = 'locked'
--   Amendment via supersedes_evaluation_id (chain model)
--
-- SCORING:
--   Instrument evaluations: score governed by form engine (form_responses layer)
--   Clinical reports: summary_score NULLABLE for holistic clinical rating
--   No separate scoring governance layer for evaluations
--   (scoring_finalization_point lives on form_templates, not here)
-- =============================================================================


-- =============================================================================
-- SECTION 1 — EVALUATION CONTEXT LOOKUP
-- =============================================================================

CREATE TABLE evaluation_context_types (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    code            TEXT        NOT NULL UNIQUE,
        -- 'diagnostic'      formal diagnosis-oriented assessment
        -- 'progress'        periodic reassessment against baseline
        -- 'discharge'       end-of-program outcome evaluation
        -- 'school_entry'    school readiness / educational placement
        -- 'insurance'       insurance-required functional assessment
        -- 'medico_legal'    court-ordered or legal proceeding evaluation
        -- 'research'        research protocol evaluation
    name            TEXT        NOT NULL,
    requires_report_sign_off BOOLEAN NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO evaluation_context_types (code, name, requires_report_sign_off) VALUES
    ('diagnostic',   'Diagnostic Assessment',         TRUE),
    ('progress',     'Progress Reassessment',         FALSE),
    ('discharge',    'Discharge Evaluation',          TRUE),
    ('school_entry', 'School Entry Evaluation',       TRUE),
    ('insurance',    'Insurance Assessment',          TRUE),
    ('medico_legal', 'Medico-Legal Evaluation',       TRUE),
    ('research',     'Research Protocol Evaluation',  FALSE);


-- =============================================================================
-- SECTION 2 — EVALUATIONS
-- =============================================================================

CREATE TABLE evaluations (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    branch_id           UUID            NOT NULL REFERENCES branches(id),
    department_id       UUID            REFERENCES departments(id),

    -- Clinical context
    patient_id          UUID            NOT NULL REFERENCES patients(id),
    lead_evaluator_id   UUID            NOT NULL,   -- user_institute_memberships.user_id
    therapy_program_id  UUID            REFERENCES therapy_programs(id),
    evaluation_context_type_id UUID     NOT NULL REFERENCES evaluation_context_types(id),

    -- Evaluation type — determines form_version_id requirement
    evaluation_type     TEXT            NOT NULL,
        -- 'instrument'       structured form-based assessment
        -- 'clinical_report'  narrative evaluation, no form instrument

    -- Instrument evaluations: form_version_id NOT NULL
    -- Clinical reports: form_version_id NULL
    form_version_id     UUID            REFERENCES form_versions(id),
    form_template_id    UUID            REFERENCES form_templates(id),

    -- Scheduling
    evaluation_date     DATE            NOT NULL,
    evaluation_duration_minutes INTEGER,
    location            TEXT,           -- 'clinic', 'home', 'school', 'tele'

    -- Clinical report content (clinical_report type)
    narrative_report    TEXT,
    clinical_findings   TEXT,
    recommendations     TEXT,

    -- Summary scoring (for clinical reports; instrument scores live in form_responses)
    summary_score       NUMERIC(10,4),
    summary_score_label TEXT,          -- 'Mild', 'Moderate', 'Severe', 'Typical'

    -- Status lifecycle (single freeze point — mirrors form_responses)
    evaluation_status   TEXT            NOT NULL DEFAULT 'draft',
        -- 'draft' → 'submitted' → 'reviewed' → 'locked'

    -- Timestamps
    submitted_at        TIMESTAMPTZ,
    reviewed_at         TIMESTAMPTZ,
    reviewed_by         UUID            REFERENCES users(id),
    locked_at           TIMESTAMPTZ,
    locked_by           UUID            REFERENCES users(id),

    -- Amendment chain
    supersedes_evaluation_id UUID       REFERENCES evaluations(id),

    -- Provenance
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- ── Composite boundary FKs ────────────────────────────────────────────────
    CONSTRAINT fk_ev_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_ev_branch_institute
        FOREIGN KEY (branch_id, institute_id)
        REFERENCES branches(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_ev_evaluator_institute
        FOREIGN KEY (lead_evaluator_id, institute_id)
        REFERENCES user_institute_memberships(user_id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_ev_program_institute
        FOREIGN KEY (therapy_program_id, institute_id)
        REFERENCES therapy_programs(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_ev_version_template
        FOREIGN KEY (form_version_id, form_template_id)
        REFERENCES form_versions(id, form_template_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- ── Conditional integrity ─────────────────────────────────────────────────
    -- [D] evaluation_type determines form_version_id requirement
    CONSTRAINT chk_ev_type_valid
        CHECK (evaluation_type IN ('instrument', 'clinical_report')),

    CONSTRAINT chk_ev_instrument_requires_form
        CHECK (
            evaluation_type != 'instrument'
            OR (form_version_id IS NOT NULL AND form_template_id IS NOT NULL)
        ),

    CONSTRAINT chk_ev_clinical_report_no_form
        CHECK (
            evaluation_type != 'clinical_report'
            OR form_version_id IS NULL
        ),

    -- narrative_report required at submission for clinical reports
    -- (enforced by trigger — see below; CHECK cannot see status transitions easily)

    -- Amendment chain
    CONSTRAINT chk_ev_no_self_supersede
        CHECK (supersedes_evaluation_id IS NULL OR supersedes_evaluation_id != id),

    -- Lifecycle timestamp ordering
    CONSTRAINT chk_ev_submitted_at_timing
        CHECK (evaluation_status = 'draft' OR submitted_at IS NOT NULL),

    CONSTRAINT chk_ev_submitted_at_null_when_draft
        CHECK (evaluation_status != 'draft' OR submitted_at IS NULL),

    CONSTRAINT chk_ev_reviewed_at_timing
        CHECK (
            reviewed_at IS NULL
            OR evaluation_status IN ('reviewed', 'locked')
        ),

    CONSTRAINT chk_ev_locked_at_timing
        CHECK (
            locked_at IS NULL
            OR evaluation_status = 'locked'
        ),

    CONSTRAINT chk_ev_reviewed_implies_submitted
        CHECK (
            evaluation_status NOT IN ('reviewed', 'locked')
            OR submitted_at IS NOT NULL
        ),

    -- Enable composite FKs from downstream tables
    CONSTRAINT uq_ev_id_institute UNIQUE (id, institute_id)
);

COMMENT ON TABLE evaluations IS
    'Clinical evaluations — instrument-based and narrative clinical reports. '
    'evaluation_type=instrument: form_version_id required, structured data via form_responses. '
    'evaluation_type=clinical_report: narrative_report carries content, form_version_id NULL. '
    'Both types freeze at evaluation_status=submitted. Absolute freeze at locked. '
    'Amendment via supersedes_evaluation_id — chain model. '
    'Scoring for instruments: governed by form engine (scoring_finalization_point). '
    'Scoring for clinical reports: summary_score nullable, freezes at submission.';

COMMENT ON COLUMN evaluations.form_version_id IS
    'NOT NULL for instrument evaluations. '
    'NULL for clinical_report evaluations. '
    'When set: composite FK ensures version belongs to the stated template. '
    'The corresponding form_responses row carries context_type=evaluation, '
    'context_ref_id=this evaluation id.';

COMMENT ON COLUMN evaluations.narrative_report IS
    'For clinical_report evaluations: the narrative evaluation content. '
    'For instrument evaluations: optional addendum or interpretation notes. '
    'Freezes at evaluation_status=submitted (enforced by trigger).';

-- Indexes
CREATE INDEX idx_ev_institute         ON evaluations(institute_id);
CREATE INDEX idx_ev_patient           ON evaluations(patient_id);
CREATE INDEX idx_ev_program           ON evaluations(therapy_program_id);
CREATE INDEX idx_ev_lead_evaluator    ON evaluations(lead_evaluator_id);
CREATE INDEX idx_ev_status            ON evaluations(institute_id, evaluation_status);
CREATE INDEX idx_ev_type              ON evaluations(evaluation_type);
CREATE INDEX idx_ev_context_type      ON evaluations(evaluation_context_type_id);
CREATE INDEX idx_ev_date              ON evaluations(patient_id, evaluation_date DESC);
CREATE INDEX idx_ev_locked            ON evaluations(patient_id, evaluation_date DESC)
    WHERE evaluation_status = 'locked';
CREATE INDEX idx_ev_supersedes        ON evaluations(supersedes_evaluation_id)
    WHERE supersedes_evaluation_id IS NOT NULL;
CREATE INDEX idx_ev_form_version      ON evaluations(form_version_id)
    WHERE form_version_id IS NOT NULL;

-- Amendment chain uniqueness (one child per original)
CREATE UNIQUE INDEX uq_ev_single_amendment
    ON evaluations(supersedes_evaluation_id)
    WHERE supersedes_evaluation_id IS NOT NULL;

COMMENT ON INDEX uq_ev_single_amendment IS
    'Chain amendment model. One amendment per original evaluation. '
    'Mirrors uq_fr_single_amendment and uq_sr_single_amendment.';


-- =============================================================================
-- SECTION 3 — EVALUATION FREEZE TRIGGER
-- =============================================================================
-- Single freeze domain (unlike session_records dual-domain).
-- All evaluation content frozen at evaluation_status='submitted'.
-- Rationale: an evaluation is a single clinical judgment event.
-- There is no scheduling/event vs documentation split.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_evaluation_freeze()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.evaluation_status IN ('submitted', 'reviewed', 'locked') THEN
        -- Core identity fields: always frozen post-submission
        IF NEW.patient_id                   IS DISTINCT FROM OLD.patient_id                OR
           NEW.lead_evaluator_id            IS DISTINCT FROM OLD.lead_evaluator_id         OR
           NEW.institute_id                 != OLD.institute_id                            OR
           NEW.branch_id                    IS DISTINCT FROM OLD.branch_id                 OR
           NEW.department_id               IS DISTINCT FROM OLD.department_id              OR
           NEW.therapy_program_id           IS DISTINCT FROM OLD.therapy_program_id        OR
           NEW.evaluation_type             != OLD.evaluation_type                          OR
           NEW.evaluation_context_type_id  != OLD.evaluation_context_type_id              OR
           NEW.form_version_id             IS DISTINCT FROM OLD.form_version_id            OR
           NEW.form_template_id            IS DISTINCT FROM OLD.form_template_id           OR
           NEW.evaluation_date             != OLD.evaluation_date                          OR
           NEW.narrative_report            IS DISTINCT FROM OLD.narrative_report           OR
           NEW.clinical_findings           IS DISTINCT FROM OLD.clinical_findings          OR
           NEW.recommendations             IS DISTINCT FROM OLD.recommendations            OR
           NEW.summary_score               IS DISTINCT FROM OLD.summary_score              OR
           NEW.summary_score_label         IS DISTINCT FROM OLD.summary_score_label
        THEN
            RAISE EXCEPTION
                'evaluation % has status=% and is frozen. '
                'Identity, content, scores, and instrument reference cannot change '
                'after evaluation submission. '
                'Use amendment workflow (supersedes_evaluation_id) for corrections.',
                OLD.id, OLD.evaluation_status;
        END IF;

        -- Absolute freeze: locked evaluations cannot change status
        IF OLD.evaluation_status = 'locked' AND
           NEW.evaluation_status IS DISTINCT FROM OLD.evaluation_status
        THEN
            RAISE EXCEPTION
                'evaluation % is locked and absolutely final. '
                'evaluation_status cannot change from locked.',
                OLD.id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_evaluation_freeze
    BEFORE UPDATE ON evaluations
    FOR EACH ROW
    EXECUTE FUNCTION enforce_evaluation_freeze();

COMMENT ON TRIGGER trg_evaluation_freeze ON evaluations IS
    'Single freeze domain: all evaluation content frozen at submitted. '
    'Unlike session_records (dual-domain), an evaluation is a single judgment event. '
    'No event-fact vs documentation split. Absolute freeze at locked.';

-- Clinical report narrative required at submission
CREATE OR REPLACE FUNCTION enforce_evaluation_clinical_report_completeness()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- On submission: clinical_report evaluations must have narrative content
    IF NEW.evaluation_status = 'submitted' AND
       OLD.evaluation_status = 'draft' AND
       NEW.evaluation_type = 'clinical_report' AND
       (NEW.narrative_report IS NULL OR TRIM(NEW.narrative_report) = '')
    THEN
        RAISE EXCEPTION
            'evaluation % (clinical_report) cannot be submitted without narrative_report. '
            'narrative_report is required for clinical_report evaluations.',
            NEW.id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_evaluation_clinical_completeness
    BEFORE UPDATE OF evaluation_status
    ON evaluations
    FOR EACH ROW
    EXECUTE FUNCTION enforce_evaluation_clinical_report_completeness();

-- Amendment integrity
CREATE OR REPLACE FUNCTION enforce_evaluation_amendment_integrity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_original_status   TEXT;
    v_original_inst     UUID;
BEGIN
    IF NEW.supersedes_evaluation_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT evaluation_status, institute_id
    INTO v_original_status, v_original_inst
    FROM evaluations
    WHERE id = NEW.supersedes_evaluation_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Evaluation amendment error: original evaluation % not found.',
            NEW.supersedes_evaluation_id;
    END IF;

    IF v_original_inst != NEW.institute_id THEN
        RAISE EXCEPTION
            'Evaluation amendment error: original evaluation % belongs to a different institute.',
            NEW.supersedes_evaluation_id;
    END IF;

    IF v_original_status NOT IN ('submitted', 'reviewed', 'locked') THEN
        RAISE EXCEPTION
            'Evaluation amendment error: original evaluation % has status=%. '
            'Amendments only created for submitted, reviewed, or locked evaluations.',
            NEW.supersedes_evaluation_id, v_original_status;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_evaluation_amendment_integrity
    BEFORE INSERT OR UPDATE OF supersedes_evaluation_id
    ON evaluations
    FOR EACH ROW
    EXECUTE FUNCTION enforce_evaluation_amendment_integrity();

-- Active evaluator membership
CREATE OR REPLACE FUNCTION enforce_evaluation_evaluator_membership()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_membership_status TEXT;
    v_is_active         BOOLEAN;
BEGIN
    IF NEW.evaluation_status NOT IN ('draft') THEN
        RETURN NEW;  -- only gate new/draft evaluations
    END IF;

    SELECT membership_status, is_active
    INTO v_membership_status, v_is_active
    FROM user_institute_memberships
    WHERE user_id    = NEW.lead_evaluator_id
      AND institute_id = NEW.institute_id;

    IF NOT FOUND OR v_membership_status != 'active' OR v_is_active = FALSE THEN
        RAISE EXCEPTION
            'evaluation: lead_evaluator % is not an active member of institute %.',
            NEW.lead_evaluator_id, NEW.institute_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_evaluation_evaluator_membership
    BEFORE INSERT OR UPDATE OF lead_evaluator_id, institute_id
    ON evaluations
    FOR EACH ROW
    EXECUTE FUNCTION enforce_evaluation_evaluator_membership();


-- =============================================================================
-- SECTION 4 — EVALUATION VERSIONS (linear audit trail)
-- =============================================================================
-- Append-only version snapshots. Same model as therapy_program_versions.
-- Auto-incremented version_number via trigger (same FOR UPDATE pattern).
-- =============================================================================

CREATE TABLE evaluation_versions (
    id                      UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    evaluation_id           UUID        NOT NULL REFERENCES evaluations(id),
    institute_id            UUID        NOT NULL REFERENCES institutes(id),
    version_number          INTEGER,    -- auto-generated by trigger
    change_reason           TEXT        NOT NULL,
    change_summary          TEXT,
    evaluation_status_snapshot TEXT     NOT NULL,
    narrative_snapshot      TEXT,
    findings_snapshot       TEXT,
    recommendations_snapshot TEXT,
    summary_score_snapshot  NUMERIC(10,4),
    effective_from          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by              UUID        NOT NULL REFERENCES users(id),

    CONSTRAINT uq_ev_version UNIQUE (evaluation_id, version_number),
    CONSTRAINT uq_ev_version_id_eval UNIQUE (id, evaluation_id),
    CONSTRAINT chk_ev_version_number_not_null CHECK (version_number IS NOT NULL)
);

-- Auto-generate version_number with FOR UPDATE lock (mirrors program versions)
CREATE OR REPLACE FUNCTION generate_evaluation_version_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_max_version INTEGER;
BEGIN
    PERFORM 1 FROM evaluations WHERE id = NEW.evaluation_id FOR UPDATE;

    SELECT COALESCE(MAX(version_number), 0) INTO v_max_version
    FROM evaluation_versions
    WHERE evaluation_id = NEW.evaluation_id;

    NEW.version_number := v_max_version + 1;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_generate_evaluation_version_number
    BEFORE INSERT ON evaluation_versions
    FOR EACH ROW
    EXECUTE FUNCTION generate_evaluation_version_number();

-- Append-only
CREATE OR REPLACE FUNCTION enforce_evaluation_version_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'evaluation_version % is an immutable audit record and cannot be modified.',
        OLD.id;
END;
$$;

CREATE TRIGGER trg_ev_version_immutable
    BEFORE UPDATE OR DELETE ON evaluation_versions
    FOR EACH ROW
    EXECUTE FUNCTION enforce_evaluation_version_immutability();

CREATE INDEX idx_evv_evaluation   ON evaluation_versions(evaluation_id);
CREATE INDEX idx_evv_institute    ON evaluation_versions(institute_id);
CREATE INDEX idx_evv_effective    ON evaluation_versions(evaluation_id, effective_from DESC);

ALTER TABLE evaluation_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE evaluation_versions FORCE ROW LEVEL SECURITY;

CREATE POLICY evv_platform_admin ON evaluation_versions
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY evv_read ON evaluation_versions
    FOR SELECT USING (
        institute_id = current_institute_id()
        AND EXISTS (
            SELECT 1 FROM evaluations ev
            WHERE ev.id = evaluation_versions.evaluation_id
              AND (
                  current_user_has_institute_scope()
                  OR current_user_assigned_to_patient(ev.patient_id)
              )
        )
    );

CREATE POLICY evv_insert ON evaluation_versions
    FOR INSERT WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_EVALUATIONS')
    );


-- =============================================================================
-- SECTION 5 — RLS ON EVALUATIONS
-- =============================================================================

ALTER TABLE evaluations ENABLE ROW LEVEL SECURITY;
ALTER TABLE evaluations FORCE ROW LEVEL SECURITY;

CREATE POLICY ev_platform_admin ON evaluations
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY ev_read ON evaluations
    FOR SELECT USING (
        institute_id = current_institute_id()
        AND (
            current_user_has_institute_scope()
            OR current_user_assigned_to_patient(patient_id)
            OR lead_evaluator_id = current_user_id()
        )
    );

CREATE POLICY ev_insert ON evaluations
    FOR INSERT WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_EVALUATIONS')
        AND current_user_assigned_to_patient(patient_id)
    );

-- Clinician update: draft only
CREATE POLICY ev_clinician_update ON evaluations
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND evaluation_status = 'draft'
        AND current_user_has_permission('CAN_MANAGE_EVALUATIONS')
        AND (
            current_user_assigned_to_patient(patient_id)
            OR lead_evaluator_id = current_user_id()
        )
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND evaluation_status IN ('draft', 'submitted')
        AND current_user_has_permission('CAN_MANAGE_EVALUATIONS')
        AND (
            current_user_assigned_to_patient(patient_id)
            OR lead_evaluator_id = current_user_id()
        )
    );

-- Supervisor review
CREATE POLICY ev_supervisor_review ON evaluations
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND evaluation_status = 'submitted'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_REVIEW_EVALUATIONS') -- Note: using existing CAN_REVIEW_SESSIONS or add new
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND evaluation_status IN ('submitted', 'reviewed')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_REVIEW_EVALUATIONS')
    );

-- Supervisor lock
CREATE POLICY ev_supervisor_lock ON evaluations
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND evaluation_status = 'reviewed'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_LOCK_EVALUATIONS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND evaluation_status IN ('reviewed', 'locked')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_LOCK_EVALUATIONS')
    );


-- =============================================================================
-- SECTION 6 — [O1] FINAL REPLACEMENT: validate_response_context_ref()
-- =============================================================================
-- evaluations table now exists. Unblock evaluation context type.
-- This is the final replacement of this function. [O1] is now closed.
-- =============================================================================

CREATE OR REPLACE FUNCTION validate_response_context_ref()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_context_code          TEXT;
    v_requires_patient      BOOLEAN;
    v_session_inst          UUID;
    v_session_patient       UUID;
    v_eval_inst             UUID;
    v_eval_patient          UUID;
BEGIN
    SELECT rct.code, rct.requires_patient_id
    INTO v_context_code, v_requires_patient
    FROM response_context_types rct
    WHERE rct.id = NEW.context_type_id;

    IF v_requires_patient AND NEW.patient_id IS NULL THEN
        RAISE EXCEPTION
            'context_type=% requires patient_id. response_id: %',
            v_context_code, NEW.id;
    END IF;

    IF v_context_code = 'patient' THEN
        IF NEW.context_ref_id IS NOT NULL THEN
            RAISE EXCEPTION
                'context_type=patient does not use context_ref_id. '
                'Set context_ref_id to NULL.';
        END IF;

    ELSIF v_context_code = 'session' THEN
        IF NEW.context_ref_id IS NULL THEN
            RAISE EXCEPTION
                'context_type=session requires context_ref_id. response_id: %', NEW.id;
        END IF;
        SELECT institute_id, patient_id INTO v_session_inst, v_session_patient
        FROM session_records WHERE id = NEW.context_ref_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'context_type=session: context_ref_id % is not a valid session_record.',
                NEW.context_ref_id;
        END IF;
        IF v_session_inst != NEW.institute_id THEN
            RAISE EXCEPTION
                'context_type=session: session % belongs to a different institute.',
                NEW.context_ref_id;
        END IF;
        IF NEW.patient_id IS NOT NULL AND NEW.patient_id != v_session_patient THEN
            RAISE EXCEPTION
                'context_type=session: response patient_id % does not match session patient_id %.',
                NEW.patient_id, v_session_patient;
        END IF;

    ELSIF v_context_code = 'evaluation' THEN
        -- [O1] FINAL UNBLOCK — evaluations table exists
        IF NEW.context_ref_id IS NULL THEN
            RAISE EXCEPTION
                'context_type=evaluation requires context_ref_id. response_id: %', NEW.id;
        END IF;
        SELECT institute_id, patient_id INTO v_eval_inst, v_eval_patient
        FROM evaluations WHERE id = NEW.context_ref_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'context_type=evaluation: context_ref_id % is not a valid evaluation.',
                NEW.context_ref_id;
        END IF;
        IF v_eval_inst != NEW.institute_id THEN
            RAISE EXCEPTION
                'context_type=evaluation: evaluation % belongs to a different institute.',
                NEW.context_ref_id;
        END IF;
        IF NEW.patient_id IS NOT NULL AND NEW.patient_id != v_eval_patient THEN
            RAISE EXCEPTION
                'context_type=evaluation: response patient_id % does not match evaluation patient_id %.',
                NEW.patient_id, v_eval_patient;
        END IF;

    END IF;
    -- 'research' and 'discharge': context_ref_id optional, no FK at this stage

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION validate_response_context_ref() IS
    '[O1] FINAL replacement. All context types now validated. '
    'patient: no context_ref_id. '
    'session: validated against session_records with institute + patient consistency. '
    'evaluation: validated against evaluations with institute + patient consistency. '
    'research/discharge: context_ref_id optional. '
    '[O1] is now fully closed. No further replacements required.';


-- =============================================================================
-- PERMISSIONS SEED — Evaluation-specific
-- =============================================================================

INSERT INTO permissions (code, name, module, description) VALUES
    ('CAN_REVIEW_EVALUATIONS', 'Review Evaluations', 'clinical',
        'Mark evaluations as reviewed (supervisor function)'),
    ('CAN_LOCK_EVALUATIONS',   'Lock Evaluations',   'clinical',
        'Clinically finalise and lock evaluations')
ON CONFLICT (code) DO NOTHING;


-- =============================================================================
-- PHASE 3 EVALUATIONS — INVENTORY
-- =============================================================================
--
-- Entry obligation completed:
--   [O1] FINAL — validate_response_context_ref() fully replaces partial version
--        All context types now validated. [O1] is closed.
--
-- Tables:
--   evaluation_context_types   (lookup, 7 seeds)
--   evaluations                (instrument + clinical_report, single freeze domain)
--   evaluation_versions        (linear append-only audit trail, auto version number)
--
-- Triggers:
--   trg_evaluation_freeze                  content frozen at submitted
--   trg_evaluation_clinical_completeness   narrative required at submission
--   trg_evaluation_amendment_integrity     amendment chain validation
--   trg_evaluation_evaluator_membership    active membership gate
--   trg_generate_evaluation_version_number FOR UPDATE auto-increment
--   trg_ev_version_immutable               append-only versions
--
-- RLS: 6 policies — read, insert, draft update, submit, review, lock
--      All WITH CHECK (lifecycle progression only, no skip-step)
--
-- Conditional integrity:
--   instrument     → form_version_id NOT NULL (CHECK constraint)
--   clinical_report → form_version_id NULL (CHECK constraint)
--   Narrative required at submission (trigger)
--
-- =============================================================================
-- COMPLETE PHASE 3 ENTRY OBLIGATION STATUS
-- =============================================================================
--   [O1] ✅ CLOSED — validate_response_context_ref() fully replaces partial
--   [O2] ✅ CLOSED — validate_case_role_scope_ref() full three-way (foundation)
--   [O3] ✅ CLOSED — supersedes_response_id on form_responses (foundation)
--
-- =============================================================================
-- NEXT: phase3_clinical_events.sql
-- =============================================================================
-- milestones, plan_change_requests, case_conferences
-- =============================================================================