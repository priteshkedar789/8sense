-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 1: FOUNDATION + GOVERNANCE SKELETON
-- =============================================================================
-- PostgreSQL 15+  |  pg_uuidv7 extension for time-ordered UUIDs
-- =============================================================================
--
-- ARCHITECTURAL TOPOLOGY (read before touching any table)
-- ─────────────────────────────────────────────────────────
-- Platform Layer    → users + is_platform_admin
-- Institute Layer   → institutes + user_institute_memberships
-- Scope Layer       → access_scopes (hierarchical: institute > branch > dept)
-- Capability Layer  → roles + permissions + role_permissions
-- Responsibility    → case_role_types + case_role_assignments
-- Relationship      → patient_provider_assignments  ← RLS anchor
-- Governance        → audit_log + access_log (append-only, privilege-enforced)
-- RLS Layer         → built on relationship + scope graph, never on role names
--
-- LOCKED RULES
-- ─────────────────────────────────────────────────────────
-- [R1]  institute_id on every institute-owned domain table. No exceptions.
-- [R2]  branch_id + department_id stored (denormalized) on operational tables.
--       Never derived at query time. Simplifies RLS dramatically.
-- [R3]  users has NO institute_id column. Membership via user_institute_memberships.
-- [R4]  is_platform_admin on users — platform governance, not institute RBAC.
-- [R5]  audit_log append-only: enforced by REVOKE + app_writer role. Trigger is belt.
-- [R6]  case_role_types NEVER references roles table. Orthogonal systems.
-- [R7]  case_role_types flags: is_supervisory, is_billable, requires_assignment.
-- [R8]  scope_level via case_scope_levels lookup table. No ENUMs for domain values.
-- [R9]  No ENUM for any extensible domain value. Lookup tables only.
-- [R10] UUID v7 (time-ordered) for all PKs. Better index locality at scale.
-- [R11] Every domain table: created_at, created_by, updated_at.
-- [R12] branch_id NOT in patient_provider_assignments uniqueness constraint.
--       Branch is contextual + denormalized. Relationship is patient↔provider↔institute.
-- [R13] RLS always starts with current_user_is_platform_admin() bypass.
--       Then resolves via patient_provider_assignments or access_scopes.
--       Never directly against role names or users columns.
-- =============================================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "pg_uuidv7";        -- time-ordered UUID v7
CREATE EXTENSION IF NOT EXISTS "pgcrypto";          -- gen_random_bytes for hashing
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements"; -- query performance monitoring

-- =============================================================================
-- DB ROLES  [R5]
-- =============================================================================
-- app_writer  : the application service account — INSERT only on audit_log
-- app_user    : normal application queries — no direct audit_log write
-- Never grant UPDATE or DELETE on audit_log to anyone.
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_writer') THEN
        CREATE ROLE app_writer;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
        CREATE ROLE app_user;
    END IF;
END
$$;


-- =============================================================================
-- SECTION 1 — ORGANISATIONAL HIERARCHY
-- =============================================================================

CREATE TABLE institutes (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    code                TEXT            NOT NULL UNIQUE,        -- 'REACH_HYD', 'REACH_BLR'
    name                TEXT            NOT NULL,
    legal_name          TEXT,
    country             TEXT            NOT NULL DEFAULT 'IN',
    timezone            TEXT            NOT NULL DEFAULT 'Asia/Kolkata',
    locale              TEXT            NOT NULL DEFAULT 'en-IN',
    contact_email       TEXT,
    contact_phone       TEXT,
    address             JSONB,
    regulatory_id       TEXT,                                   -- MCI / state reg number
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID,                                   -- FK set after users table
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE institutes IS
    'Root tenant entity. [R1] Every institute-owned domain table carries institute_id. '
    'Platform super admin sees across institutes. Institute RBAC is bounded here.';

-- ---------------------------------------------------------------------------

CREATE TABLE branches (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    code                TEXT            NOT NULL,
    name                TEXT            NOT NULL,
    city                TEXT,
    state               TEXT,
    address             JSONB,
    contact_email       TEXT,
    contact_phone       TEXT,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    opened_on           DATE,
    closed_on           DATE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID,
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_branch_code_per_institute UNIQUE (institute_id, code)
);

CREATE INDEX idx_branches_institute         ON branches(institute_id);

-- ---------------------------------------------------------------------------

CREATE TABLE departments (
    id                      UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id            UUID        NOT NULL REFERENCES institutes(id),
    branch_id               UUID        REFERENCES branches(id),    -- NULL = institute-wide
    code                    TEXT        NOT NULL,
    name                    TEXT        NOT NULL,
    description             TEXT,
    parent_department_id    UUID        REFERENCES departments(id), -- sub-dept support
    is_clinical             BOOLEAN     NOT NULL DEFAULT TRUE,
    is_research             BOOLEAN     NOT NULL DEFAULT FALSE,
    is_active               BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by              UUID,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_dept_code_per_branch UNIQUE (institute_id, branch_id, code)
);

CREATE INDEX idx_departments_institute      ON departments(institute_id);
CREATE INDEX idx_departments_branch         ON departments(branch_id);
CREATE INDEX idx_departments_parent         ON departments(parent_department_id);

-- ---------------------------------------------------------------------------

CREATE TABLE units (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    branch_id           UUID            NOT NULL REFERENCES branches(id),
    department_id       UUID            NOT NULL REFERENCES departments(id),
    code                TEXT            NOT NULL,
    name                TEXT            NOT NULL,
    unit_type           TEXT            NOT NULL,
        -- 'therapy_room','assessment_bay','tele_cabin','sensory_room','gym','classroom'
    capacity            INTEGER,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID,
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_unit_code_per_dept UNIQUE (institute_id, branch_id, department_id, code)
);

CREATE INDEX idx_units_institute            ON units(institute_id);
CREATE INDEX idx_units_branch               ON units(branch_id);
CREATE INDEX idx_units_department           ON units(department_id);

-- ---------------------------------------------------------------------------

CREATE TABLE resources (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    branch_id           UUID            NOT NULL REFERENCES branches(id),
    department_id       UUID            REFERENCES departments(id), -- NULL = branch-shared
    unit_id             UUID            REFERENCES units(id),
    code                TEXT            NOT NULL,
    name                TEXT            NOT NULL,
    resource_type       TEXT            NOT NULL,
        -- 'room','equipment','vehicle','tele_link','assessment_kit'
    metadata            JSONB,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID,
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_resource_code_per_branch UNIQUE (institute_id, branch_id, code)
);

CREATE INDEX idx_resources_institute        ON resources(institute_id);
CREATE INDEX idx_resources_branch           ON resources(branch_id);
CREATE INDEX idx_resources_type             ON resources(resource_type);


-- =============================================================================
-- SECTION 2 — PLATFORM USERS  [R3] [R4]
-- =============================================================================
-- users has NO institute_id column.
-- Institute membership is in user_institute_memberships.
-- is_platform_admin is platform governance — outside institute RBAC entirely.
-- =============================================================================

CREATE TABLE users (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    email               TEXT            NOT NULL UNIQUE,
    phone               TEXT,
    full_name           TEXT            NOT NULL,
    display_name        TEXT,
    is_platform_admin   BOOLEAN         NOT NULL DEFAULT FALSE,  -- [R4]
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    is_verified         BOOLEAN         NOT NULL DEFAULT FALSE,
    last_login_at       TIMESTAMPTZ,
    deactivated_at      TIMESTAMPTZ,
    metadata            JSONB,          -- external IDs, SSO ref, HR system ref
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE users IS
    '[R3] No institute_id here. Platform entity. '
    'Institute membership via user_institute_memberships. '
    '[R4] is_platform_admin bypasses all institute RLS — platform governance only.';

CREATE INDEX idx_users_email                ON users(email);
CREATE INDEX idx_users_active               ON users(is_active);
CREATE INDEX idx_users_platform_admin       ON users(is_platform_admin)
    WHERE is_platform_admin = TRUE;

-- ---------------------------------------------------------------------------
-- Institute membership: source of truth for user ↔ institute relationship  [R3]
-- ---------------------------------------------------------------------------

CREATE TABLE user_institute_memberships (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    user_id             UUID            NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    employee_code       TEXT,
    user_type           TEXT            NOT NULL,
        -- 'therapist','evaluator','admin','researcher','intern',
        -- 'extern_consultant','billing','compliance','supervisor'
    default_branch_id   UUID            REFERENCES branches(id),   -- home branch
    membership_status   TEXT            NOT NULL DEFAULT 'active',
        -- 'active','suspended','terminated','on_leave'
    joined_on           DATE,
    ended_on            DATE,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_user_institute UNIQUE (user_id, institute_id),
    CONSTRAINT uq_employee_code_per_institute UNIQUE (institute_id, employee_code)
);

COMMENT ON TABLE user_institute_memberships IS
    'A user may belong to multiple institutes (e.g. external consultant, group practice). '
    'RLS resolves current institute context via app.current_institute_id session variable.';

CREATE INDEX idx_uim_user                   ON user_institute_memberships(user_id);
CREATE INDEX idx_uim_institute              ON user_institute_memberships(institute_id);
CREATE INDEX idx_uim_active                 ON user_institute_memberships(institute_id, is_active);
CREATE INDEX idx_uim_type                   ON user_institute_memberships(institute_id, user_type);


-- =============================================================================
-- SECTION 3 — RBAC: CAPABILITY LAYER
-- =============================================================================
-- Answers: "What is this user allowed to DO in the system?"
-- Never answers: "Which patients can they see?" (that is RLS + assignments)
-- Never answers: "What is their clinical relationship to a patient?" (case roles)
-- =============================================================================

CREATE TABLE roles (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    code                TEXT            NOT NULL,
    name                TEXT            NOT NULL,
    description         TEXT,
    is_system_role      BOOLEAN         NOT NULL DEFAULT FALSE,  -- protected, cannot delete
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_role_code_per_institute UNIQUE (institute_id, code)
);

CREATE INDEX idx_roles_institute            ON roles(institute_id);

-- ---------------------------------------------------------------------------

CREATE TABLE permissions (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    code                TEXT            NOT NULL UNIQUE,
        -- 'CAN_CREATE_EVALUATION'    'CAN_APPROVE_PROGRAM'
        -- 'CAN_VIEW_FINANCIALS'      'CAN_EXPORT_RESEARCH_DATA'
        -- 'CAN_EDIT_SCHEDULE'        'CAN_VIEW_AUDIT_LOG'
        -- 'CAN_MANAGE_USERS'         'CAN_DISCHARGE_PATIENT'
    name                TEXT            NOT NULL,
    module              TEXT            NOT NULL,
        -- 'clinical','billing','admin','research','scheduling','compliance'
    description         TEXT,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id)
);

COMMENT ON TABLE permissions IS
    'Atomic, platform-level capability codes. Additive only — never delete, only deactivate. '
    'NOT linked to clinical case relationships. Orthogonal to case_role_types.';

CREATE INDEX idx_permissions_module         ON permissions(module);

-- ---------------------------------------------------------------------------

CREATE TABLE role_permissions (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    role_id             UUID            NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_id       UUID            NOT NULL REFERENCES permissions(id),
    granted_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    granted_by          UUID            REFERENCES users(id),

    CONSTRAINT uq_role_permission UNIQUE (role_id, permission_id)
);

CREATE INDEX idx_role_permissions_role      ON role_permissions(role_id);
CREATE INDEX idx_role_permissions_perm      ON role_permissions(permission_id);

-- ---------------------------------------------------------------------------
-- Access scopes: hierarchical scope model  [R8]
-- institute > branch > department
-- A role assigned at institute scope sees all branches.
-- A role assigned at branch scope sees only that branch.
-- NO cross_branch flags. Hierarchy resolves visibility.
-- ---------------------------------------------------------------------------

CREATE TABLE access_scopes (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    scope_type          TEXT            NOT NULL,
        -- 'institute' | 'branch' | 'department' | 'unit' | 'program'
    branch_id           UUID            REFERENCES branches(id),       -- NULL if institute-scope
    department_id       UUID            REFERENCES departments(id),    -- NULL unless dept-scope
    label               TEXT,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),

    CONSTRAINT uq_scope_per_institute UNIQUE (institute_id, scope_type, branch_id, department_id)
);

COMMENT ON TABLE access_scopes IS
    'Hierarchical scope model. No cross_branch flags — hierarchy resolves visibility. '
    'institute-level scope → all branches visible. '
    'branch-level scope → single branch visible. '
    'department-level scope → single department visible.';

CREATE INDEX idx_access_scopes_institute    ON access_scopes(institute_id);
CREATE INDEX idx_access_scopes_type         ON access_scopes(scope_type);
CREATE INDEX idx_access_scopes_branch       ON access_scopes(branch_id);

-- ---------------------------------------------------------------------------

CREATE TABLE user_role_assignments (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    user_id             UUID            NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id             UUID            NOT NULL REFERENCES roles(id),
    access_scope_id     UUID            REFERENCES access_scopes(id), -- NULL = institute-wide
    assigned_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    assigned_by         UUID            REFERENCES users(id),
    expires_at          TIMESTAMPTZ,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    deactivated_at      TIMESTAMPTZ,
    deactivated_by      UUID            REFERENCES users(id),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_user_role_scope UNIQUE (user_id, role_id, access_scope_id)
);

CREATE INDEX idx_ura_user                   ON user_role_assignments(user_id);
CREATE INDEX idx_ura_role                   ON user_role_assignments(role_id);
CREATE INDEX idx_ura_scope                  ON user_role_assignments(access_scope_id);
CREATE INDEX idx_ura_institute              ON user_role_assignments(institute_id);
CREATE INDEX idx_ura_active                 ON user_role_assignments(user_id, is_active)
    WHERE is_active = TRUE;


-- =============================================================================
-- SECTION 4 — GOVERNANCE INFRASTRUCTURE  [R5]
-- =============================================================================
-- audit_log  : append-only, partitioned monthly, REVOKE enforced
-- access_log : append-only, login/permission events, partitioned quarterly
-- Both created BEFORE any domain table.
-- log_audit() called by application service on every critical write.
-- =============================================================================

CREATE TABLE audit_log (
    id              BIGSERIAL,
    institute_id    UUID            NOT NULL,
    actor_id        UUID,                       -- NULL = system/cron job
    actor_ip        INET,
    actor_context   TEXT,                       -- hashed session token or API key ref
    action          TEXT            NOT NULL,
        -- 'INSERT','DEACTIVATE','EXPORT'
        -- 'CONSENT_GIVEN','CONSENT_REVOKED'
        -- 'PERMISSION_GRANTED','PERMISSION_REVOKED'
        -- 'PATIENT_TRANSFER','BRANCH_TRANSFER'
        -- 'PROGRAM_APPROVED','SESSION_COMPLETED'
    table_name      TEXT            NOT NULL,
    record_id       UUID,
    old_values      JSONB,
    new_values      JSONB,
    delta           JSONB,                      -- changed key-value pairs only
    metadata        JSONB,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    PRIMARY KEY (id, created_at)    -- composite PK required for partitioning
)
PARTITION BY RANGE (created_at);

COMMENT ON TABLE audit_log IS
    '[R5] Append-only. REVOKE UPDATE, DELETE enforced at DB privilege level. '
    'Trigger is secondary enforcement. Partitioned monthly via pg_partman in production.';

-- Starter partitions — production should use pg_partman for automation
CREATE TABLE audit_log_2025_q3 PARTITION OF audit_log
    FOR VALUES FROM ('2025-07-01') TO ('2025-10-01');
CREATE TABLE audit_log_2025_q4 PARTITION OF audit_log
    FOR VALUES FROM ('2025-10-01') TO ('2026-01-01');
CREATE TABLE audit_log_2026_q1 PARTITION OF audit_log
    FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');
CREATE TABLE audit_log_2026_q2 PARTITION OF audit_log
    FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');
CREATE TABLE audit_log_2026_q3 PARTITION OF audit_log
    FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');
CREATE TABLE audit_log_2026_q4 PARTITION OF audit_log
    FOR VALUES FROM ('2026-10-01') TO ('2027-01-01');

-- Privilege enforcement  [R5]
REVOKE UPDATE, DELETE ON audit_log FROM PUBLIC;
GRANT INSERT ON audit_log TO app_writer;
GRANT SELECT ON audit_log TO app_user;

-- Trigger as belt-and-suspenders (privileges are the primary lock)
CREATE OR REPLACE FUNCTION enforce_audit_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'audit_log is append-only. % is not permitted. '
        'Revoke the DB privilege — do not fight the trigger.',
        TG_OP;
END;
$$;

CREATE TRIGGER trg_audit_log_immutable
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION enforce_audit_immutability();

-- log_audit() — called by application service layer on every critical write
CREATE OR REPLACE FUNCTION log_audit(
    p_institute_id  UUID,
    p_actor_id      UUID,
    p_actor_ip      INET,
    p_action        TEXT,
    p_table_name    TEXT,
    p_record_id     UUID,
    p_old_values    JSONB DEFAULT NULL,
    p_new_values    JSONB DEFAULT NULL,
    p_metadata      JSONB DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO audit_log (
        institute_id, actor_id, actor_ip,
        action, table_name, record_id,
        old_values, new_values, delta, metadata
    ) VALUES (
        p_institute_id, p_actor_id, p_actor_ip,
        p_action, p_table_name, p_record_id,
        p_old_values, p_new_values,
        CASE
            WHEN p_old_values IS NOT NULL AND p_new_values IS NOT NULL THEN (
                SELECT jsonb_object_agg(n.key, n.value)
                FROM jsonb_each(p_new_values) n
                WHERE p_new_values -> n.key IS DISTINCT FROM p_old_values -> n.key
            )
            ELSE NULL
        END,
        p_metadata
    );
END;
$$;

-- Indexes on partitioned table apply to all partitions
CREATE INDEX idx_audit_log_institute        ON audit_log(institute_id);
CREATE INDEX idx_audit_log_actor            ON audit_log(actor_id);
CREATE INDEX idx_audit_log_table_record     ON audit_log(table_name, record_id);
CREATE INDEX idx_audit_log_action           ON audit_log(action);
CREATE INDEX idx_audit_log_created          ON audit_log(created_at DESC);

-- ---------------------------------------------------------------------------

CREATE TABLE access_log (
    id              BIGSERIAL,
    institute_id    UUID            NOT NULL,
    user_id         UUID,           -- soft ref: no FK on partitioned table
    session_ref     TEXT,           -- hashed session token
    ip_address      INET,
    user_agent      TEXT,
    action          TEXT            NOT NULL,
        -- 'LOGIN','LOGOUT','TOKEN_REFRESH','FAILED_LOGIN',
        -- 'PERMISSION_DENIED','RESOURCE_ACCESS','EXPORT_TRIGGERED'
    resource_type   TEXT,
    resource_id     UUID,
    success         BOOLEAN         NOT NULL DEFAULT TRUE,
    failure_reason  TEXT,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    PRIMARY KEY (id, created_at)
)
PARTITION BY RANGE (created_at);

CREATE TABLE access_log_2025_q3 PARTITION OF access_log
    FOR VALUES FROM ('2025-07-01') TO ('2025-10-01');
CREATE TABLE access_log_2025_q4 PARTITION OF access_log
    FOR VALUES FROM ('2025-10-01') TO ('2026-01-01');
CREATE TABLE access_log_2026_q1 PARTITION OF access_log
    FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');
CREATE TABLE access_log_2026_q2 PARTITION OF access_log
    FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');
CREATE TABLE access_log_2026_q3 PARTITION OF access_log
    FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');
CREATE TABLE access_log_2026_q4 PARTITION OF access_log
    FOR VALUES FROM ('2026-10-01') TO ('2027-01-01');

REVOKE UPDATE, DELETE ON access_log FROM PUBLIC;
GRANT INSERT ON access_log TO app_writer;
GRANT SELECT ON access_log TO app_user;

CREATE INDEX idx_access_log_institute       ON access_log(institute_id);
CREATE INDEX idx_access_log_user            ON access_log(user_id);
CREATE INDEX idx_access_log_created         ON access_log(created_at DESC);
CREATE INDEX idx_access_log_action          ON access_log(action, success);


-- =============================================================================
-- SECTION 5 — PATIENT & GUARDIAN FOUNDATION
-- =============================================================================

CREATE TABLE patients (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    branch_id           UUID            NOT NULL REFERENCES branches(id),   -- registration branch [R2]
    mrn                 TEXT            NOT NULL,                           -- medical record number
    full_name           TEXT            NOT NULL,
    date_of_birth       DATE            NOT NULL,
    gender              TEXT,
    blood_group         TEXT,
    contact_phone       TEXT,
    contact_email       TEXT,
    address             JSONB,
    is_minor            BOOLEAN         NOT NULL
                            GENERATED ALWAYS AS
                            (date_of_birth > (CURRENT_DATE - INTERVAL '18 years')) STORED,
    patient_status      TEXT            NOT NULL DEFAULT 'registered',
        -- lookup: patient_status_types (Phase 2)
        -- 'registered','intake','active','paused','discharged','re_entered'
    registration_date   DATE            NOT NULL DEFAULT CURRENT_DATE,
    discharge_date      DATE,
    re_entry_count      INTEGER         NOT NULL DEFAULT 0,
    primary_language    TEXT            DEFAULT 'en',
    emergency_contact   JSONB,
    metadata            JSONB,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),               -- [R11]
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_mrn_per_institute UNIQUE (institute_id, mrn)
);

CREATE INDEX idx_patients_institute         ON patients(institute_id);
CREATE INDEX idx_patients_branch            ON patients(branch_id);
CREATE INDEX idx_patients_status            ON patients(institute_id, patient_status);
CREATE INDEX idx_patients_dob               ON patients(date_of_birth);
CREATE INDEX idx_patients_name_fts          ON patients
    USING gin(to_tsvector('simple', full_name));
CREATE INDEX idx_patients_active            ON patients(institute_id, is_active)
    WHERE is_active = TRUE;

-- ---------------------------------------------------------------------------

CREATE TABLE guardians (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    full_name           TEXT            NOT NULL,
    relationship        TEXT            NOT NULL,
        -- 'mother','father','legal_guardian','sibling','caregiver','spouse'
    contact_phone       TEXT,
    contact_email       TEXT,
    address             JSONB,
    id_type             TEXT,           -- 'aadhaar','passport','voter_id','driving_licence'
    id_number_hash      TEXT,           -- [DPDP] NEVER store raw govt ID. Hash only.
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_guardians_institute        ON guardians(institute_id);

-- ---------------------------------------------------------------------------

CREATE TABLE patient_guardian_links (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    patient_id          UUID            NOT NULL REFERENCES patients(id),
    guardian_id         UUID            NOT NULL REFERENCES guardians(id),
    is_primary          BOOLEAN         NOT NULL DEFAULT FALSE,
    is_legal_guardian   BOOLEAN         NOT NULL DEFAULT FALSE,
    can_consent         BOOLEAN         NOT NULL DEFAULT FALSE,
    linked_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    unlinked_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),

    CONSTRAINT uq_patient_guardian UNIQUE (patient_id, guardian_id)
);

CREATE INDEX idx_pgl_patient                ON patient_guardian_links(patient_id);
CREATE INDEX idx_pgl_guardian               ON patient_guardian_links(guardian_id);
CREATE INDEX idx_pgl_institute              ON patient_guardian_links(institute_id);

-- ---------------------------------------------------------------------------
-- DPDP Consent — soft audit trail  [DPDP]
-- Consent blocks clinical actions at the APPLICATION layer.
-- No RLS enforcement on SELECT — per governance decision.
-- Never UPDATE a consent row. Revocation = new row with is_active=false.
-- ---------------------------------------------------------------------------

CREATE TABLE consent_records (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    patient_id          UUID            NOT NULL REFERENCES patients(id),
    consented_by_id     UUID            NOT NULL,   -- guardian.id or patient.id (soft ref)
    consented_by_type   TEXT            NOT NULL,
        -- 'guardian','patient_self','legal_representative'
    consent_type        TEXT            NOT NULL,
        -- 'treatment','data_sharing','research','photography',
        -- 'tele_session','insurance_disclosure','video_recording'
    consent_version     TEXT            NOT NULL,   -- document version e.g. 'v2.1'
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    given_at            TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    expires_at          TIMESTAMPTZ,
    revoked_at          TIMESTAMPTZ,
    revoked_by          UUID            REFERENCES users(id),
    revocation_reason   TEXT,
    ip_address          INET,
    signature_ref       TEXT,           -- object storage path to signed document
    metadata            JSONB,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id)
);

COMMENT ON TABLE consent_records IS
    'DPDP audit trail. Append-pattern: never UPDATE. '
    'Active consent query: patient_id=X AND consent_type=Y AND is_active=true '
    'AND (expires_at IS NULL OR expires_at > NOW()). '
    'Application checks this before any clinical action. RLS does not enforce SELECT.';

CREATE INDEX idx_consent_patient            ON consent_records(patient_id);
CREATE INDEX idx_consent_institute          ON consent_records(institute_id);
CREATE INDEX idx_consent_type_active        ON consent_records(patient_id, consent_type, is_active);
CREATE INDEX idx_consent_expiry             ON consent_records(expires_at)
    WHERE is_active = TRUE AND expires_at IS NOT NULL;


-- =============================================================================
-- SECTION 6 — PROVIDER-PATIENT RELATIONSHIP LAYER
-- =============================================================================
-- This is the RLS anchor for ALL clinical tables in all future phases.
-- "Which provider is permitted to access which patient?"
-- RBAC (Section 3) answers: "What can they do?"
-- This section answers: "Which patients can they see at all?"
-- Both checks required. Neither replaces the other.
-- =============================================================================

-- Maps patients to departments they are enrolled in  [R2]
CREATE TABLE patient_department_mapping (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    patient_id          UUID            NOT NULL REFERENCES patients(id),
    department_id       UUID            NOT NULL REFERENCES departments(id),
    branch_id           UUID            NOT NULL REFERENCES branches(id),   -- [R2]
    enrolled_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    enrolled_by         UUID            REFERENCES users(id),
    discharged_at       TIMESTAMPTZ,
    discharged_by       UUID            REFERENCES users(id),
    discharge_reason    TEXT,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),

    CONSTRAINT uq_patient_dept_branch UNIQUE (patient_id, department_id, branch_id)
);

CREATE INDEX idx_pdm_patient                ON patient_department_mapping(patient_id);
CREATE INDEX idx_pdm_department             ON patient_department_mapping(department_id);
CREATE INDEX idx_pdm_institute              ON patient_department_mapping(institute_id);
CREATE INDEX idx_pdm_active                 ON patient_department_mapping(department_id, is_active)
    WHERE is_active = TRUE;

-- ---------------------------------------------------------------------------
-- Core RLS anchor  [R12] [R13]
-- branch_id is denormalized here for RLS query performance.
-- branch_id is NOT in the uniqueness constraint. [R12]
-- Cross-branch assignment within same institute is supported.
-- ---------------------------------------------------------------------------

CREATE TABLE patient_provider_assignments (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    patient_id          UUID            NOT NULL REFERENCES patients(id),
    provider_id         UUID            NOT NULL REFERENCES users(id),
    branch_id           UUID            NOT NULL REFERENCES branches(id),   -- denorm [R2], NOT in UK
    department_id       UUID            REFERENCES departments(id),
    assigned_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    assigned_by         UUID            REFERENCES users(id),
    unassigned_at       TIMESTAMPTZ,
    unassigned_by       UUID            REFERENCES users(id),
    unassignment_reason TEXT,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- [R12] branch_id intentionally excluded from uniqueness constraint
    CONSTRAINT uq_provider_patient_dept
        UNIQUE (patient_id, provider_id, department_id)
);

COMMENT ON TABLE patient_provider_assignments IS
    'RLS anchor for all clinical tables. Removing a row here immediately revokes access. '
    'branch_id is denormalized for RLS performance, NOT a uniqueness dimension. [R12] '
    'Cross-branch assignment within same institute is fully supported. '
    'Cross-institute assignment is impossible by design (institute_id enforces boundary).';

CREATE INDEX idx_ppa_patient                ON patient_provider_assignments(patient_id);
CREATE INDEX idx_ppa_provider               ON patient_provider_assignments(provider_id);
CREATE INDEX idx_ppa_institute              ON patient_provider_assignments(institute_id);
CREATE INDEX idx_ppa_branch                 ON patient_provider_assignments(branch_id);
CREATE INDEX idx_ppa_active                 ON patient_provider_assignments(provider_id, is_active)
    WHERE is_active = TRUE;

-- ---------------------------------------------------------------------------
-- Provider to department staffing (organisational, not clinical assignment)
-- ---------------------------------------------------------------------------

CREATE TABLE provider_department_mapping (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    provider_id         UUID            NOT NULL REFERENCES users(id),
    department_id       UUID            NOT NULL REFERENCES departments(id),
    branch_id           UUID            NOT NULL REFERENCES branches(id),   -- [R2]
    is_primary_dept     BOOLEAN         NOT NULL DEFAULT FALSE,
    joined_dept_at      DATE,
    left_dept_at        DATE,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),

    CONSTRAINT uq_provider_dept_branch UNIQUE (provider_id, department_id, branch_id)
);

CREATE INDEX idx_prdm_provider              ON provider_department_mapping(provider_id);
CREATE INDEX idx_prdm_department            ON provider_department_mapping(department_id);
CREATE INDEX idx_prdm_institute             ON provider_department_mapping(institute_id);


-- =============================================================================
-- SECTION 7 — CASE ROLE SYSTEM: RESPONSIBILITY LAYER  [R6] [R7] [R8]
-- =============================================================================
-- Completely separate from RBAC. Orthogonal systems.
-- case_role_types NEVER references roles table.
-- scope_level via lookup table — no ENUMs.
-- =============================================================================

-- Lookup table for scope levels  [R8]
CREATE TABLE case_scope_levels (
    id              UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    code            TEXT            NOT NULL UNIQUE,
        -- 'patient' | 'program' | 'department'
    name            TEXT            NOT NULL,
    description     TEXT,
    sort_order      INTEGER         NOT NULL DEFAULT 0,
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- Seed values (immutable in practice, but not constrained — institute can extend)
INSERT INTO case_scope_levels (code, name, description, sort_order) VALUES
    ('patient',    'Patient',    'Role scoped to a single patient case',       1),
    ('program',    'Program',    'Role scoped to a therapy program',           2),
    ('department', 'Department', 'Supervisory role scoped to a department',    3);

-- ---------------------------------------------------------------------------

CREATE TABLE case_role_types (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    code                TEXT            NOT NULL,
        -- 'primary_therapist','secondary_therapist','evaluator',
        -- 'case_coordinator','department_supervisor','intern_observer','reviewer'
    name                TEXT            NOT NULL,
    description         TEXT,
    -- Soft hints for UI and analytics. Hard enforcement stays in RBAC permissions.
    allows_edit         BOOLEAN         NOT NULL DEFAULT FALSE,
    allows_evaluate     BOOLEAN         NOT NULL DEFAULT FALSE,
    allows_approve      BOOLEAN         NOT NULL DEFAULT FALSE,
    is_supervisory      BOOLEAN         NOT NULL DEFAULT FALSE,  -- [R7]
    is_billable         BOOLEAN         NOT NULL DEFAULT FALSE,  -- [R7] used in payroll Phase 5
    requires_assignment BOOLEAN         NOT NULL DEFAULT TRUE,   -- [R7] must be explicitly assigned
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_case_role_code_per_institute UNIQUE (institute_id, code)
);

COMMENT ON TABLE case_role_types IS
    '[R6] NO relationship to RBAC roles table. Orthogonal systems. '
    'System Roles = capability. Case Roles = clinical responsibility. '
    'is_billable used in Phase 5 payroll logic. '
    'is_supervisory used for department oversight queries.';

CREATE INDEX idx_case_role_types_institute  ON case_role_types(institute_id);

-- ---------------------------------------------------------------------------

CREATE TABLE case_role_assignments (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    provider_id         UUID            NOT NULL REFERENCES users(id),
    case_role_type_id   UUID            NOT NULL REFERENCES case_role_types(id),
    scope_level_id      UUID            NOT NULL REFERENCES case_scope_levels(id), -- [R8]
    scope_ref_id        UUID            NOT NULL,
        -- patient.id     when scope_level = 'patient'
        -- program.id     when scope_level = 'program'   (Phase 2 table)
        -- department.id  when scope_level = 'department'
    branch_id           UUID            REFERENCES branches(id),    -- denorm [R2]
    assigned_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    assigned_by         UUID            REFERENCES users(id),
    unassigned_at       TIMESTAMPTZ,
    unassigned_by       UUID            REFERENCES users(id),
    notes               TEXT,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_case_role_per_scope
        UNIQUE (provider_id, case_role_type_id, scope_level_id, scope_ref_id)
);

COMMENT ON TABLE case_role_assignments IS
    'Governs clinical responsibility relationships. '
    'scope_level=patient    → provider is primary/secondary/etc. for one patient. '
    'scope_level=program    → provider oversees a therapy program (Phase 2). '
    'scope_level=department → department supervisor. '
    'RBAC (can they do X?) and case role (are they responsible for Y?) are separate checks.';

CREATE INDEX idx_cra_provider               ON case_role_assignments(provider_id);
CREATE INDEX idx_cra_role_type              ON case_role_assignments(case_role_type_id);
CREATE INDEX idx_cra_scope_ref              ON case_role_assignments(scope_level_id, scope_ref_id);
CREATE INDEX idx_cra_institute              ON case_role_assignments(institute_id);
CREATE INDEX idx_cra_active                 ON case_role_assignments(provider_id, is_active)
    WHERE is_active = TRUE;


-- =============================================================================
-- SECTION 8 — RLS POLICIES  [R13]
-- =============================================================================
-- Every policy starts with current_user_is_platform_admin() bypass.
-- Then resolves via patient_provider_assignments or access_scopes.
-- NEVER resolves directly against role names or users columns.
-- =============================================================================

-- Session variable helpers
-- Application sets at connection time:
--   SET LOCAL app.current_user_id      = '<uuid>';
--   SET LOCAL app.current_institute_id = '<uuid>';

CREATE OR REPLACE FUNCTION current_user_id()
RETURNS UUID LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT nullif(current_setting('app.current_user_id', TRUE), '')::UUID
$$;

CREATE OR REPLACE FUNCTION current_institute_id()
RETURNS UUID LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT nullif(current_setting('app.current_institute_id', TRUE), '')::UUID
$$;

-- Platform admin bypass  [R4] [R13]
CREATE OR REPLACE FUNCTION current_user_is_platform_admin()
RETURNS BOOLEAN LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT COALESCE(
        (SELECT is_platform_admin FROM users
         WHERE id = current_user_id() AND is_active = TRUE),
        FALSE
    )
$$;

-- Does current user have an active role with a specific permission in current institute?
CREATE OR REPLACE FUNCTION current_user_has_permission(p_permission_code TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM user_role_assignments ura
        JOIN role_permissions rp ON rp.role_id = ura.role_id
        JOIN permissions p       ON p.id = rp.permission_id
        WHERE ura.user_id      = current_user_id()
          AND ura.institute_id = current_institute_id()
          AND ura.is_active    = TRUE
          AND (ura.expires_at IS NULL OR ura.expires_at > NOW())
          AND p.code           = p_permission_code
          AND p.is_active      = TRUE
    )
$$;

-- Is current user assigned to this patient (the core RLS check)?
CREATE OR REPLACE FUNCTION current_user_assigned_to_patient(p_patient_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM patient_provider_assignments ppa
        WHERE ppa.patient_id   = p_patient_id
          AND ppa.provider_id  = current_user_id()
          AND ppa.institute_id = current_institute_id()
          AND ppa.is_active    = TRUE
    )
$$;

-- Has institute-wide scope (department head, compliance, research)
CREATE OR REPLACE FUNCTION current_user_has_institute_scope()
RETURNS BOOLEAN LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM user_role_assignments ura
        JOIN access_scopes s ON s.id = ura.access_scope_id
        WHERE ura.user_id      = current_user_id()
          AND ura.institute_id = current_institute_id()
          AND ura.is_active    = TRUE
          AND (ura.expires_at IS NULL OR ura.expires_at > NOW())
          AND s.scope_type     = 'institute'
    )
$$;

-- ── patients ────────────────────────────────────────────────────────────────

ALTER TABLE patients ENABLE ROW LEVEL SECURITY;
ALTER TABLE patients FORCE ROW LEVEL SECURITY;  -- applies to table owner too

CREATE POLICY patients_platform_admin ON patients
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY patients_institute_scope ON patients
    FOR SELECT
    USING (
        institute_id = current_institute_id()
        AND current_user_has_institute_scope()
    );

CREATE POLICY patients_assigned_provider ON patients
    FOR SELECT
    USING (
        institute_id = current_institute_id()
        AND current_user_assigned_to_patient(id)
    );

CREATE POLICY patients_insert ON patients
    FOR INSERT
    WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_REGISTER_PATIENT')
    );

-- ── consent_records ──────────────────────────────────────────────────────────

ALTER TABLE consent_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE consent_records FORCE ROW LEVEL SECURITY;

CREATE POLICY consent_platform_admin ON consent_records
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY consent_provider ON consent_records
    FOR SELECT
    USING (
        institute_id = current_institute_id()
        AND (
            current_user_has_institute_scope()
            OR current_user_assigned_to_patient(patient_id)
        )
    );

-- ── patient_department_mapping ───────────────────────────────────────────────

ALTER TABLE patient_department_mapping ENABLE ROW LEVEL SECURITY;
ALTER TABLE patient_department_mapping FORCE ROW LEVEL SECURITY;

CREATE POLICY pdm_platform_admin ON patient_department_mapping
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY pdm_provider ON patient_department_mapping
    FOR SELECT
    USING (
        institute_id = current_institute_id()
        AND (
            current_user_has_institute_scope()
            OR current_user_assigned_to_patient(patient_id)
        )
    );

-- ── case_role_assignments ────────────────────────────────────────────────────

ALTER TABLE case_role_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE case_role_assignments FORCE ROW LEVEL SECURITY;

CREATE POLICY cra_platform_admin ON case_role_assignments
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY cra_own_assignments ON case_role_assignments
    FOR SELECT
    USING (
        institute_id = current_institute_id()
        AND (
            provider_id = current_user_id()
            OR current_user_has_institute_scope()
        )
    );

-- ── NOTE on audit_log and access_log ────────────────────────────────────────
-- RLS intentionally NOT applied to audit_log / access_log.
-- Reason: Recursive policy evaluation risk on INSERT via triggers.
-- Access is controlled at application layer via CAN_VIEW_AUDIT_LOG permission.
-- These tables are only exposed through a dedicated compliance API route.
-- ────────────────────────────────────────────────────────────────────────────


-- =============================================================================
-- SECTION 9 — ADD DEFERRED FK BACK-REFERENCES
-- =============================================================================
-- Some self-referential and cross-table FKs that could not be declared inline
-- =============================================================================

ALTER TABLE institutes
    ADD CONSTRAINT fk_institutes_created_by
    FOREIGN KEY (created_by) REFERENCES users(id) DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE branches
    ADD CONSTRAINT fk_branches_created_by
    FOREIGN KEY (created_by) REFERENCES users(id);

ALTER TABLE departments
    ADD CONSTRAINT fk_departments_created_by
    FOREIGN KEY (created_by) REFERENCES users(id);

ALTER TABLE units
    ADD CONSTRAINT fk_units_created_by
    FOREIGN KEY (created_by) REFERENCES users(id);

ALTER TABLE resources
    ADD CONSTRAINT fk_resources_created_by
    FOREIGN KEY (created_by) REFERENCES users(id);

ALTER TABLE patients
    ADD CONSTRAINT fk_patients_created_by
    FOREIGN KEY (created_by) REFERENCES users(id);


-- =============================================================================
-- SECTION 10 — PRODUCTION SETUP NOTES
-- =============================================================================
--
-- pg_partman (automated partition management):
--   SELECT partman.create_parent(
--       p_parent_table => 'public.audit_log',
--       p_control      => 'created_at',
--       p_type         => 'range',
--       p_interval     => 'monthly',
--       p_premake      => 3
--   );
--   Add to pg_cron: SELECT partman.run_maintenance_proc();
--   Repeat for access_log.
--
-- UUID v7 (pg_uuidv7):
--   If pg_uuidv7 is unavailable: use application-layer generation
--   (e.g. ulidx, uuid7 npm package) and pass UUID as parameter.
--   Never fall back to gen_random_uuid() for domain tables — index fragmentation.
--
-- Session variables (application sets these at connection time):
--   SET LOCAL app.current_user_id      = '<uuid>';
--   SET LOCAL app.current_institute_id = '<uuid>';
--   Use PgBouncer transaction mode — reset vars on each transaction.
--
-- app_writer role grants (run as superuser after schema creation):
--   GRANT app_writer TO <your_application_db_user>;
--
-- =============================================================================


-- =============================================================================
-- PHASE 1 COMPLETE — INVENTORY
-- =============================================================================
--
-- Org hierarchy    : institutes, branches, departments, units, resources
--
-- Platform users   : users (no institute_id), user_institute_memberships
--
-- RBAC             : roles, permissions, role_permissions,
--                    access_scopes, user_role_assignments
--
-- Governance       : audit_log (partitioned, append-only, privilege-enforced)
--                    access_log (partitioned, append-only, privilege-enforced)
--                    log_audit() function, enforce_audit_immutability() trigger
--
-- Patients         : patients, guardians, patient_guardian_links,
--                    consent_records
--
-- Relationships    : patient_department_mapping,
--                    patient_provider_assignments   ← RLS anchor
--                    provider_department_mapping
--
-- Case roles       : case_scope_levels (lookup),
--                    case_role_types,
--                    case_role_assignments
--
-- RLS helpers      : current_user_id(), current_institute_id(),
--                    current_user_is_platform_admin(),
--                    current_user_has_permission(),
--                    current_user_assigned_to_patient(),
--                    current_user_has_institute_scope()
--
-- RLS policies     : patients (select/insert), consent_records,
--                    patient_department_mapping, case_role_assignments
--
-- =============================================================================
-- PHASE 2 WILL COVER
-- =============================================================================
-- Dynamic form system  : form_templates, form_versions, form_fields,
--                        field_validation_rules, conditional_logic,
--                        form_responses
-- Clinical core        : therapy_types (lookup), evaluations,
--                        therapy_programs, therapy_program_versions,
--                        session_records, milestones, case_conferences
-- All Phase 2 tables   : inherit RLS pattern from patient_provider_assignments
-- =============================================================================
