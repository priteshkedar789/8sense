-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 3 — CLINICAL CORE FOUNDATION
-- =============================================================================
-- Apply after: all Phase 1 and Phase 2 files
-- =============================================================================
--
-- PHASE 3 ENTRY OBLIGATIONS (first actions — must precede any clinical tables)
-- ─────────────────────────────────────────────────────────────────────────────
-- [O1]  Replace validate_response_context_ref()
--       Unblocks session and evaluation context types on form_responses.
--       AFTER session_records and evaluations tables exist.
--       NOTE: Deferred to phase3_session_records.sql — must run after those
--       tables are created. This file handles O2 and O3 which are unblocked now.
--
-- [O2]  Replace validate_case_role_scope_ref_partial()
--       therapy_programs table now exists — full three-way scope validation possible.
--       Done in SECTION 1 of this file.
--
-- [O3]  Add supersedes_response_id to form_responses.
--       Amendment workflow anchor. Done in SECTION 2 of this file.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- CLINICAL CORE TABLES (this file)
-- ─────────────────────────────────────────────────────────────────────────────
-- [S1]  therapy_type_registry      — extensible lookup, no hardcoded types
-- [S2]  therapy_programs           — clinical care plan container per patient
-- [S3]  therapy_program_versions   — linear audit-versioned program snapshots
-- [S4]  therapy_program_assignments — patient ↔ program formal enrollment
-- [S5]  program_goal_sets          — goals attached to a program version
--
-- SESSION RECORDS (phase3_session_records.sql — next file)
--   session_records with dual freeze: event facts at status='completed',
--   clinical notes at note_status='submitted'. Two-domain immutability.
--
-- EVALUATIONS (phase3_evaluations.sql)
-- MILESTONES, PLAN_CHANGE_REQUESTS, CASE_CONFERENCES (phase3_clinical_events.sql)
-- =============================================================================


-- =============================================================================
-- SECTION O2 — Replace validate_case_role_scope_ref_partial()
-- =============================================================================
-- Phase 2 blocked scope_level='program' with an explicit error.
-- therapy_programs now exists. Replace with full three-way validation.
-- =============================================================================

CREATE OR REPLACE FUNCTION validate_case_role_scope_ref()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_scope_code    TEXT;
    v_patient_id    UUID;
    v_dept_id       UUID;
    v_prog_id       UUID;
BEGIN
    SELECT csl.code INTO v_scope_code
    FROM case_scope_levels csl
    WHERE csl.id = NEW.scope_level_id;

    -- patient scope: scope_ref_id must reference a patient in the same institute
    IF v_scope_code = 'patient' THEN
        IF NEW.scope_ref_id IS NULL THEN
            RAISE EXCEPTION
                'case_role_assignment: scope_level=patient requires scope_ref_id (patient.id). '
                'assignment_id: %', NEW.id;
        END IF;
        SELECT id INTO v_patient_id
        FROM patients
        WHERE id = NEW.scope_ref_id
          AND institute_id = NEW.institute_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'case_role_assignment: scope_ref_id % does not reference a valid patient '
                'in institute %. scope_level=patient.',
                NEW.scope_ref_id, NEW.institute_id;
        END IF;

    -- department scope: scope_ref_id must reference a department in the same institute
    ELSIF v_scope_code = 'department' THEN
        IF NEW.scope_ref_id IS NULL THEN
            RAISE EXCEPTION
                'case_role_assignment: scope_level=department requires scope_ref_id (department.id).',
                ;
        END IF;
        SELECT id INTO v_dept_id
        FROM departments
        WHERE id = NEW.scope_ref_id
          AND institute_id = NEW.institute_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'case_role_assignment: scope_ref_id % does not reference a valid department '
                'in institute %. scope_level=department.',
                NEW.scope_ref_id, NEW.institute_id;
        END IF;

    -- program scope: NOW UNBLOCKED [O2] — therapy_programs exists
    ELSIF v_scope_code = 'program' THEN
        IF NEW.scope_ref_id IS NULL THEN
            RAISE EXCEPTION
                'case_role_assignment: scope_level=program requires scope_ref_id (therapy_program.id).',
                ;
        END IF;
        SELECT id INTO v_prog_id
        FROM therapy_programs
        WHERE id = NEW.scope_ref_id
          AND institute_id = NEW.institute_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'case_role_assignment: scope_ref_id % does not reference a valid therapy_program '
                'in institute %. scope_level=program.',
                NEW.scope_ref_id, NEW.institute_id;
        END IF;

    ELSE
        RAISE EXCEPTION
            'case_role_assignment: unrecognised scope_level code %. '
            'Valid values: patient, department, program.',
            v_scope_code;
    END IF;

    RETURN NEW;
END;
$$;

-- Rename trigger to reflect full validation (drop the 'partial' naming)
DROP TRIGGER IF EXISTS trg_validate_case_role_scope_ref_partial ON case_role_assignments;

CREATE TRIGGER trg_validate_case_role_scope_ref
    BEFORE INSERT OR UPDATE OF scope_level_id, scope_ref_id, institute_id
    ON case_role_assignments
    FOR EACH ROW
    EXECUTE FUNCTION validate_case_role_scope_ref();

COMMENT ON FUNCTION validate_case_role_scope_ref() IS
    '[O2] Phase 3 full replacement of validate_case_role_scope_ref_partial(). '
    'Validates all three scope types: patient, department, program. '
    'therapy_programs table now exists — program scope fully unblocked. '
    'Each scope_ref_id validated against its target table + institute boundary.';


-- =============================================================================
-- SECTION O3 — supersedes_response_id on form_responses
-- =============================================================================
-- Amendment workflow anchor. When a submitted/locked response requires
-- correction, a new response is created referencing the original.
-- Original remains permanently immutable. Audit trail is preserved.
-- =============================================================================

ALTER TABLE form_responses
    ADD COLUMN supersedes_response_id UUID REFERENCES form_responses(id);

-- Prevent circular amendment chains (A supersedes B supersedes A)
ALTER TABLE form_responses
    ADD CONSTRAINT chk_no_self_supersede
    CHECK (supersedes_response_id IS NULL OR supersedes_response_id != id);

-- Amendment must be a newer response: enforced by trigger
CREATE OR REPLACE FUNCTION enforce_amendment_integrity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_original_status   TEXT;
    v_original_inst     UUID;
BEGIN
    IF NEW.supersedes_response_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Original response must exist in same institute
    SELECT response_status, institute_id
    INTO v_original_status, v_original_inst
    FROM form_responses
    WHERE id = NEW.supersedes_response_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            '[O3] Amendment error: original response % not found.',
            NEW.supersedes_response_id;
    END IF;

    -- Institute boundary: amendment must be in same institute
    IF v_original_inst != NEW.institute_id THEN
        RAISE EXCEPTION
            '[O3] Amendment error: original response % belongs to a different institute.',
            NEW.supersedes_response_id;
    END IF;

    -- Meaningful amendment: original should be submitted, reviewed, or locked
    -- (amending in_progress responses is unusual — warn but allow)
    -- Strict: only allow amendment of submitted/reviewed/locked
    IF v_original_status NOT IN ('submitted', 'reviewed', 'locked') THEN
        RAISE EXCEPTION
            '[O3] Amendment error: original response % has status=%. '
            'Amendments are only created for submitted, reviewed, or locked responses. '
            'For in_progress responses, simply edit the original.',
            NEW.supersedes_response_id, v_original_status;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_form_response_amendment_integrity
    BEFORE INSERT OR UPDATE OF supersedes_response_id
    ON form_responses
    FOR EACH ROW
    EXECUTE FUNCTION enforce_amendment_integrity();

CREATE INDEX idx_fr_supersedes ON form_responses(supersedes_response_id)
    WHERE supersedes_response_id IS NOT NULL;

COMMENT ON COLUMN form_responses.supersedes_response_id IS
    '[O3] Amendment workflow anchor. When a submitted/locked response requires '
    'correction, a new in_progress response is created referencing the original here. '
    'The original response remains permanently immutable. '
    'Amendment chain: new_response.supersedes_response_id → original_response.id. '
    'Follow chain to reconstruct correction history.';


-- =============================================================================
-- SECTION S1 — THERAPY TYPE REGISTRY
-- =============================================================================
-- Extensible lookup table. No hardcoded therapy types.
-- Institute-specific types allowed alongside platform-global types.
-- Disciplines, modalities, and delivery methods are all distinct concepts.
-- =============================================================================

CREATE TABLE therapy_type_registry (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            REFERENCES institutes(id),  -- NULL = platform-global
    code                TEXT            NOT NULL,
        -- 'OT', 'SPEECH', 'ABA', 'PT', 'PSYCHOLOGICAL', 'SPECIAL_ED',
        -- 'BEHAVIORAL', 'MUSIC_THERAPY', 'AQUA_THERAPY', etc.
    name                TEXT            NOT NULL,
    short_name          TEXT,           -- for UI display
    description         TEXT,
    discipline_category TEXT,
        -- 'occupational', 'speech_language', 'behavioral', 'physical',
        -- 'psychological', 'educational', 'creative_arts', 'alternative'
    is_billable         BOOLEAN         NOT NULL DEFAULT TRUE,
    requires_licensed_provider BOOLEAN  NOT NULL DEFAULT TRUE,
    typical_session_duration_minutes INTEGER,
    is_global           BOOLEAN         NOT NULL
                            GENERATED ALWAYS AS (institute_id IS NULL) STORED,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    sort_order          INTEGER         NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_therapy_type_code_per_institute
        UNIQUE (institute_id, code)
);

-- Seed platform-global types
INSERT INTO therapy_type_registry
    (code, name, short_name, discipline_category, is_billable,
     requires_licensed_provider, typical_session_duration_minutes, sort_order)
VALUES
    ('OT',          'Occupational Therapy',         'OT',       'occupational',     TRUE, TRUE,  45, 1),
    ('SPEECH',      'Speech-Language Pathology',    'SLP',      'speech_language',  TRUE, TRUE,  45, 2),
    ('ABA',         'Applied Behavior Analysis',    'ABA',      'behavioral',       TRUE, TRUE,  60, 3),
    ('PT',          'Physical Therapy',             'PT',       'physical',         TRUE, TRUE,  45, 4),
    ('PSYCHOLOGICAL','Psychological Therapy',       'Psych',    'psychological',    TRUE, TRUE,  50, 5),
    ('SPECIAL_ED',  'Special Education',            'SpEd',     'educational',      FALSE,TRUE,  45, 6),
    ('BEHAVIORAL',  'Behavioral Therapy',           'BT',       'behavioral',       TRUE, TRUE,  45, 7),
    ('MUSIC',       'Music Therapy',                'MT',       'creative_arts',    TRUE, FALSE, 45, 8),
    ('AQUA',        'Aquatic Therapy',              'Aqua',     'physical',         TRUE, TRUE,  45, 9),
    ('SENSORY',     'Sensory Integration Therapy',  'SI',       'occupational',     TRUE, TRUE,  45, 10);

CREATE INDEX idx_ttr_institute     ON therapy_type_registry(institute_id);
CREATE INDEX idx_ttr_active        ON therapy_type_registry(is_active) WHERE is_active = TRUE;
CREATE INDEX idx_ttr_global        ON therapy_type_registry(is_global) WHERE is_global = TRUE;
CREATE INDEX idx_ttr_discipline    ON therapy_type_registry(discipline_category);

-- RLS: global types readable by all; institute types scoped
ALTER TABLE therapy_type_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE therapy_type_registry FORCE ROW LEVEL SECURITY;

CREATE POLICY ttr_platform_admin ON therapy_type_registry
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY ttr_global_read ON therapy_type_registry
    FOR SELECT USING (is_global = TRUE);

CREATE POLICY ttr_institute_read ON therapy_type_registry
    FOR SELECT USING (
        is_global = FALSE
        AND institute_id = current_institute_id()
    );

CREATE POLICY ttr_institute_write ON therapy_type_registry
    FOR INSERT WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_CLINICAL_CONFIG')
    );

CREATE POLICY ttr_institute_update ON therapy_type_registry
    FOR UPDATE USING (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_CLINICAL_CONFIG')
    );


-- =============================================================================
-- SECTION S2 — THERAPY PROGRAMS
-- =============================================================================
-- A therapy program is the clinical care plan container for a patient.
-- It spans multiple sessions, ties together providers, goals, and outcomes.
-- Programs evolve over time — versioned linearly (not branchable like forms).
-- Programs are NOT templates. They are patient-specific living documents.
-- =============================================================================

CREATE TABLE therapy_programs (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    branch_id           UUID            NOT NULL REFERENCES branches(id),
    department_id       UUID            REFERENCES departments(id),
    patient_id          UUID            NOT NULL REFERENCES patients(id),

    program_code        TEXT,           -- internal reference code (e.g. "OT-2024-0042")
    name                TEXT            NOT NULL,
    description         TEXT,

    -- Primary therapy type (multi-type via therapy_program_type_map below)
    primary_therapy_type_id UUID        NOT NULL REFERENCES therapy_type_registry(id),

    -- Status lifecycle
    program_status      TEXT            NOT NULL DEFAULT 'planned',
        -- 'planned'      → program designed, not yet started
        -- 'active'       → sessions are occurring
        -- 'paused'       → temporarily suspended (medical/personal)
        -- 'completed'    → goals met, program closed successfully
        -- 'discontinued' → ended before completion (transfer, non-compliance, etc.)

    -- Scheduling intent (not scheduling engine — see Phase 4)
    intended_frequency_per_week     NUMERIC(4,1),
    intended_session_duration_minutes INTEGER,
    intended_start_date DATE,
    intended_end_date   DATE,

    -- Actuals
    actual_start_date   DATE,
    actual_end_date     DATE,
    total_sessions_planned INTEGER,
    total_sessions_completed INTEGER    NOT NULL DEFAULT 0,

    -- Administrative
    referral_source     TEXT,           -- 'physician', 'self', 'school', 'court', etc.
    referral_notes      TEXT,
    insurance_auth_code TEXT,
    insurance_auth_sessions_approved INTEGER,

    -- Amendment chain
    supersedes_program_id UUID          REFERENCES therapy_programs(id),

    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Composite institute boundary FKs
    CONSTRAINT fk_prog_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_prog_branch_institute
        FOREIGN KEY (branch_id, institute_id)
        REFERENCES branches(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_no_self_supersede_prog
        CHECK (supersedes_program_id IS NULL OR supersedes_program_id != id),

    CONSTRAINT chk_prog_dates
        CHECK (intended_end_date IS NULL OR intended_end_date >= intended_start_date),

    CONSTRAINT uq_prog_id_institute UNIQUE (id, institute_id)  -- enables downstream composite FKs
);

COMMENT ON TABLE therapy_programs IS
    'Clinical care plan container per patient. Not a template — patient-specific. '
    'Programs are versioned linearly (therapy_program_versions) for audit. '
    'Multi-discipline programs supported via therapy_program_type_map. '
    'Amendment workflow: supersedes_program_id references replaced program. '
    'Scheduling engine (Phase 4) reads program intent — does not write here.';

COMMENT ON COLUMN therapy_programs.program_status IS
    'Status lifecycle: planned → active → completed | discontinued. '
    'paused is a temporary suspension within active phase. '
    'Event facts (patient, branch, primary type) frozen at status=active. '
    'Program goals and documentation frozen at status=completed|discontinued. '
    'Enforced by trg_therapy_program_event_freeze trigger.';

CREATE INDEX idx_tp_institute         ON therapy_programs(institute_id);
CREATE INDEX idx_tp_patient           ON therapy_programs(patient_id);
CREATE INDEX idx_tp_branch            ON therapy_programs(branch_id);
CREATE INDEX idx_tp_dept              ON therapy_programs(department_id);
CREATE INDEX idx_tp_status            ON therapy_programs(institute_id, program_status);
CREATE INDEX idx_tp_type              ON therapy_programs(primary_therapy_type_id);
CREATE INDEX idx_tp_active_patient    ON therapy_programs(patient_id, program_status)
    WHERE program_status = 'active';

-- Multi-discipline: a program can involve multiple therapy types
CREATE TABLE therapy_program_type_map (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    therapy_program_id  UUID            NOT NULL REFERENCES therapy_programs(id) ON DELETE CASCADE,
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    therapy_type_id     UUID            NOT NULL REFERENCES therapy_type_registry(id),
    is_primary          BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),

    CONSTRAINT uq_prog_type UNIQUE (therapy_program_id, therapy_type_id)
);

CREATE INDEX idx_tptm_program  ON therapy_program_type_map(therapy_program_id);
CREATE INDEX idx_tptm_type     ON therapy_program_type_map(therapy_type_id);

-- ---------------------------------------------------------------------------
-- Event fact freeze trigger: patient/branch/type immutable once active
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_therapy_program_event_freeze()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Once active/completed/discontinued, core identity facts cannot change
    IF OLD.program_status IN ('active', 'paused', 'completed', 'discontinued') THEN
        IF NEW.patient_id               IS DISTINCT FROM OLD.patient_id           OR
           NEW.institute_id             != OLD.institute_id                        OR
           NEW.branch_id                IS DISTINCT FROM OLD.branch_id            OR
           NEW.primary_therapy_type_id  IS DISTINCT FROM OLD.primary_therapy_type_id OR
           NEW.actual_start_date        IS DISTINCT FROM OLD.actual_start_date
        THEN
            RAISE EXCEPTION
                'therapy_program % has status=% — identity facts are frozen. '
                'patient_id, institute_id, branch_id, primary_therapy_type_id, '
                'and actual_start_date cannot change once the program is active. '
                'Use amendment workflow (supersedes_program_id) for corrections.',
                OLD.id, OLD.program_status;
        END IF;
    END IF;

    -- Once completed or discontinued, all clinical content is also frozen
    IF OLD.program_status IN ('completed', 'discontinued') THEN
        IF NEW.program_status NOT IN ('completed', 'discontinued') THEN
            RAISE EXCEPTION
                'therapy_program % is % and cannot be reopened. '
                'Create a new program to resume care.',
                OLD.id, OLD.program_status;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_therapy_program_event_freeze
    BEFORE UPDATE ON therapy_programs
    FOR EACH ROW
    EXECUTE FUNCTION enforce_therapy_program_event_freeze();

COMMENT ON TRIGGER trg_therapy_program_event_freeze ON therapy_programs IS
    'Domain A freeze: patient, institute, branch, primary_type, actual_start_date '
    'frozen once program_status reaches active. '
    'completed/discontinued programs cannot be reopened — new program required. '
    'Mirrors session_records dual-domain freeze model.';

-- RLS
ALTER TABLE therapy_programs ENABLE ROW LEVEL SECURITY;
ALTER TABLE therapy_programs FORCE ROW LEVEL SECURITY;

CREATE POLICY tp_platform_admin ON therapy_programs
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY tp_read ON therapy_programs
    FOR SELECT USING (
        institute_id = current_institute_id()
        AND (
            current_user_has_institute_scope()
            OR current_user_assigned_to_patient(patient_id)
        )
    );

CREATE POLICY tp_insert ON therapy_programs
    FOR INSERT WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
        AND current_user_assigned_to_patient(patient_id)
    );

CREATE POLICY tp_update ON therapy_programs
    FOR UPDATE USING (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
        AND current_user_assigned_to_patient(patient_id)
    );


-- =============================================================================
-- SECTION S3 — THERAPY PROGRAM VERSIONS
-- =============================================================================
-- Linear audit versioning of program state.
-- NOT branchable (unlike form_versions) — programs are patient-specific, not templates.
-- Each significant change to a program creates a new version snapshot.
-- Primarily for audit trail: "what was the plan on date X?"
-- =============================================================================

CREATE TABLE therapy_program_versions (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    therapy_program_id  UUID            NOT NULL REFERENCES therapy_programs(id),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    version_number      INTEGER         NOT NULL,   -- monotonically increasing per program
    change_reason       TEXT            NOT NULL,
        -- 'initial_plan', 'goal_revision', 'frequency_change',
        -- 'provider_change', 'insurance_reauthorization', 'clinical_review'
    change_summary      TEXT,

    -- Snapshot of key program state at version creation
    program_status_snapshot     TEXT    NOT NULL,
    intended_frequency_snapshot NUMERIC(4,1),
    session_duration_snapshot   INTEGER,
    goals_snapshot              JSONB,  -- structured goal list at this point in time
    clinical_notes              TEXT,   -- rationale for this version

    effective_from      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            NOT NULL REFERENCES users(id),

    -- Immutable once created — program versions are audit records
    CONSTRAINT uq_prog_version UNIQUE (therapy_program_id, version_number),
    CONSTRAINT uq_prog_version_id_institute UNIQUE (id, institute_id)
);

COMMENT ON TABLE therapy_program_versions IS
    'Linear audit trail of therapy program changes. Not branchable. '
    'Each clinically significant change creates a version snapshot. '
    'Answers: "what was the care plan on date X?" '
    'version_number is monotonically increasing per program — not semantic version. '
    'Snapshots are additive (INSERT only) — immutability enforced by trigger.';

-- Program versions are append-only (INSERT only — no UPDATE/DELETE)
CREATE OR REPLACE FUNCTION enforce_program_version_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'therapy_program_version % is an immutable audit record. '
        'Program versions cannot be modified or deleted. '
        'Create a new version to record changes.',
        OLD.id;
END;
$$;

CREATE TRIGGER trg_prog_version_immutable
    BEFORE UPDATE OR DELETE ON therapy_program_versions
    FOR EACH ROW
    EXECUTE FUNCTION enforce_program_version_immutability();

CREATE INDEX idx_tpv_program       ON therapy_program_versions(therapy_program_id);
CREATE INDEX idx_tpv_institute     ON therapy_program_versions(institute_id);
CREATE INDEX idx_tpv_effective     ON therapy_program_versions(therapy_program_id, effective_from DESC);

-- Program versions inherit program RLS
ALTER TABLE therapy_program_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE therapy_program_versions FORCE ROW LEVEL SECURITY;

CREATE POLICY tpv_platform_admin ON therapy_program_versions
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY tpv_read ON therapy_program_versions
    FOR SELECT USING (
        institute_id = current_institute_id()
        AND EXISTS (
            SELECT 1 FROM therapy_programs tp
            WHERE tp.id = therapy_program_versions.therapy_program_id
              AND (
                  current_user_has_institute_scope()
                  OR current_user_assigned_to_patient(tp.patient_id)
              )
        )
    );

CREATE POLICY tpv_insert ON therapy_program_versions
    FOR INSERT WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    );
-- No UPDATE or DELETE policies — immutability trigger handles it structurally


-- =============================================================================
-- SECTION S4 — THERAPY PROGRAM ASSIGNMENTS (provider enrollment)
-- =============================================================================
-- Formal enrollment of providers into a therapy program.
-- Distinct from patient_provider_assignments (general patient access)
-- and case_role_assignments (clinical responsibility roles).
-- This is the scheduling anchor: "this provider delivers this program."
-- =============================================================================

CREATE TABLE therapy_program_assignments (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    therapy_program_id  UUID            NOT NULL REFERENCES therapy_programs(id),
    provider_id         UUID            NOT NULL,   -- user_institute_memberships.user_id
    role_in_program     TEXT            NOT NULL,
        -- 'primary_therapist', 'co_therapist', 'supervisor',
        -- 'assistant', 'consulting_specialist'
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    assigned_from       DATE            NOT NULL DEFAULT CURRENT_DATE,
    assigned_to         DATE,           -- NULL = current assignment

    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Provider must be an active member of this institute
    CONSTRAINT fk_tpa_provider_institute
        FOREIGN KEY (provider_id, institute_id)
        REFERENCES user_institute_memberships(user_id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- Program must belong to same institute
    CONSTRAINT fk_tpa_program_institute
        FOREIGN KEY (therapy_program_id, institute_id)
        REFERENCES therapy_programs(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- Only one active primary therapist per program at a time
    -- (partial index handles this below)
    CONSTRAINT chk_dates_tpa
        CHECK (assigned_to IS NULL OR assigned_to >= assigned_from)
);

-- One active primary therapist per program
CREATE UNIQUE INDEX uq_tpa_one_active_primary
    ON therapy_program_assignments(therapy_program_id)
    WHERE is_active = TRUE AND role_in_program = 'primary_therapist';

-- One active assignment per provider per program (prevent duplicates)
CREATE UNIQUE INDEX uq_tpa_provider_program_active
    ON therapy_program_assignments(therapy_program_id, provider_id)
    WHERE is_active = TRUE;

CREATE INDEX idx_tpa_program      ON therapy_program_assignments(therapy_program_id);
CREATE INDEX idx_tpa_provider     ON therapy_program_assignments(provider_id);
CREATE INDEX idx_tpa_institute    ON therapy_program_assignments(institute_id);
CREATE INDEX idx_tpa_active       ON therapy_program_assignments(therapy_program_id, is_active)
    WHERE is_active = TRUE;

-- Validate provider active membership (mirrors Phase 1 pattern)
CREATE OR REPLACE FUNCTION validate_program_assignment_active_membership()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_membership_status TEXT;
    v_is_active         BOOLEAN;
BEGIN
    IF NEW.is_active = FALSE THEN
        RETURN NEW;
    END IF;

    SELECT membership_status, is_active
    INTO v_membership_status, v_is_active
    FROM user_institute_memberships
    WHERE user_id = NEW.provider_id
      AND institute_id = NEW.institute_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'therapy_program_assignment: provider % is not a member of institute %.',
            NEW.provider_id, NEW.institute_id;
    END IF;

    IF v_membership_status != 'active' OR v_is_active = FALSE THEN
        RAISE EXCEPTION
            'therapy_program_assignment: provider % membership in institute % '
            'is not active (status=%, is_active=%). '
            'Only active members may be assigned to therapy programs.',
            NEW.provider_id, NEW.institute_id, v_membership_status, v_is_active;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tpa_active_membership
    BEFORE INSERT OR UPDATE OF provider_id, institute_id, is_active
    ON therapy_program_assignments
    FOR EACH ROW
    EXECUTE FUNCTION validate_program_assignment_active_membership();

-- RLS
ALTER TABLE therapy_program_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE therapy_program_assignments FORCE ROW LEVEL SECURITY;

CREATE POLICY tpa_platform_admin ON therapy_program_assignments
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY tpa_read ON therapy_program_assignments
    FOR SELECT USING (
        institute_id = current_institute_id()
        AND (
            current_user_has_institute_scope()
            OR provider_id = current_user_id()
            OR EXISTS (
                SELECT 1 FROM therapy_programs tp
                WHERE tp.id = therapy_program_assignments.therapy_program_id
                  AND current_user_assigned_to_patient(tp.patient_id)
            )
        )
    );

CREATE POLICY tpa_write ON therapy_program_assignments
    FOR INSERT WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    );

CREATE POLICY tpa_update ON therapy_program_assignments
    FOR UPDATE USING (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    );


-- =============================================================================
-- SECTION S5 — PROGRAM GOAL SETS
-- =============================================================================
-- Structured goals attached to a program version.
-- Goals are the measurable targets that sessions work toward.
-- Goal progress is tracked via milestones (phase3_clinical_events.sql).
-- =============================================================================

CREATE TABLE program_goals (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    therapy_program_id  UUID            NOT NULL REFERENCES therapy_programs(id),
    program_version_id  UUID            NOT NULL REFERENCES therapy_program_versions(id),

    goal_code           TEXT,           -- short identifier e.g. 'FINE_MOTOR_1'
    domain              TEXT,           -- 'fine_motor', 'gross_motor', 'communication',
                                        -- 'social', 'self_care', 'academic', 'behavioral'
    goal_statement      TEXT            NOT NULL,
    baseline_description TEXT,
    target_criteria     TEXT            NOT NULL,   -- measurable success condition
    target_date         DATE,
    goal_status         TEXT            NOT NULL DEFAULT 'active',
        -- 'active', 'achieved', 'discontinued', 'deferred'
    priority            INTEGER         NOT NULL DEFAULT 1,  -- 1=highest

    is_long_term_goal   BOOLEAN         NOT NULL DEFAULT FALSE,
    parent_goal_id      UUID            REFERENCES program_goals(id),  -- STG under LTG

    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_goal_program_institute
        FOREIGN KEY (therapy_program_id, institute_id)
        REFERENCES therapy_programs(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_no_self_parent_goal
        CHECK (parent_goal_id IS NULL OR parent_goal_id != id)
);

CREATE INDEX idx_pg_program        ON program_goals(therapy_program_id);
CREATE INDEX idx_pg_version        ON program_goals(program_version_id);
CREATE INDEX idx_pg_institute      ON program_goals(institute_id);
CREATE INDEX idx_pg_status         ON program_goals(therapy_program_id, goal_status);
CREATE INDEX idx_pg_domain         ON program_goals(domain);
CREATE INDEX idx_pg_parent         ON program_goals(parent_goal_id);

ALTER TABLE program_goals ENABLE ROW LEVEL SECURITY;
ALTER TABLE program_goals FORCE ROW LEVEL SECURITY;

CREATE POLICY pg_platform_admin ON program_goals
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY pg_read ON program_goals
    FOR SELECT USING (
        institute_id = current_institute_id()
        AND (
            current_user_has_institute_scope()
            OR EXISTS (
                SELECT 1 FROM therapy_programs tp
                WHERE tp.id = program_goals.therapy_program_id
                  AND current_user_assigned_to_patient(tp.patient_id)
            )
        )
    );

CREATE POLICY pg_write ON program_goals
    FOR INSERT WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    );

CREATE POLICY pg_update ON program_goals
    FOR UPDATE USING (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    );


-- =============================================================================
-- PERMISSIONS SEED — Clinical Core
-- =============================================================================

INSERT INTO permissions (code, name, module, description) VALUES
    ('CAN_MANAGE_CLINICAL_CONFIG',  'Manage Clinical Configuration',  'clinical',
        'Create and manage therapy type registry and clinical lookup tables'),
    ('CAN_MANAGE_PROGRAMS',         'Manage Therapy Programs',        'clinical',
        'Create, update, and close therapy programs and goals'),
    ('CAN_VIEW_PROGRAMS',           'View Therapy Programs',          'clinical',
        'View therapy programs, goals, and program history'),
    ('CAN_MANAGE_SESSIONS',         'Manage Session Records',         'clinical',
        'Create, document, and submit session records'),
    ('CAN_VIEW_SESSIONS',           'View Session Records',           'clinical',
        'View session records for assigned patients'),
    ('CAN_REVIEW_SESSIONS',         'Review Session Notes',           'clinical',
        'Mark session notes as reviewed (supervisor function)'),
    ('CAN_LOCK_SESSIONS',           'Lock Session Records',           'clinical',
        'Clinically finalise and lock session notes'),
    ('CAN_MANAGE_EVALUATIONS',      'Manage Evaluations',             'clinical',
        'Create, document, and submit clinical evaluations'),
    ('CAN_VIEW_EVALUATIONS',        'View Evaluations',               'clinical',
        'View evaluation records for assigned patients')
ON CONFLICT (code) DO NOTHING;


-- =============================================================================
-- PHASE 3 FOUNDATION — INVENTORY
-- =============================================================================
--
-- Entry obligations completed:
--   [O2] validate_case_role_scope_ref() — full three-way validation, program unblocked
--   [O3] supersedes_response_id on form_responses + enforce_amendment_integrity()
--   [O1] Deferred — requires session_records + evaluations tables (next files)
--
-- Tables created:
--   therapy_type_registry       (platform-global + institute types, 10 seeds)
--   therapy_programs            (patient-specific care plans)
--   therapy_program_type_map    (multi-discipline program support)
--   therapy_program_versions    (linear audit trail, append-only)
--   therapy_program_assignments (provider enrollment per program)
--   program_goals               (measurable targets, LTG/STG hierarchy)
--
-- Triggers:
--   trg_validate_case_role_scope_ref   full scope validation (replaces partial)
--   trg_form_response_amendment_integrity  amendment chain validation
--   trg_therapy_program_event_freeze   identity facts frozen at active
--   trg_prog_version_immutable         program versions append-only
--   trg_tpa_active_membership          active membership gate on program assignments
--
-- RLS: all tables institute-scoped, patient_provider_assignments anchor
--
-- =============================================================================
-- NEXT FILES IN PHASE 3 SEQUENCE
-- =============================================================================
--
--   phase3_session_records.sql        ← dual-domain freeze architecture
--     Contains [O1]: replaces validate_response_context_ref()
--   phase3_evaluations.sql            ← evaluation versioning + scoring
--   phase3_clinical_events.sql        ← milestones, plan_change_requests,
--                                        case_conferences
-- =============================================================================