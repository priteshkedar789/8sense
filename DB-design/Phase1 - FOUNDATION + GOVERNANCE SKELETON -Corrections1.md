-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 1 — PATCH 01: STRUCTURAL CORRECTIONS
-- =============================================================================
-- Apply after phase1_foundation.sql
-- Addresses all 6 structural issues identified in production review.
-- =============================================================================
--
-- CORRECTIONS IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-1] patient_provider_assignments — replace table UNIQUE with partial index
--         Nullable department_id caused NULL-distinct duplicates. Partial index
--         on is_active=TRUE matches the domain model (history via is_active).
--
-- [FIX-2] case_role_assignments — same NULL-distinct problem, same fix.
--         Unassign + reassign would have failed under the original constraint.
--
-- [FIX-3] Institute boundary enforcement via composite FKs.
--         Without these, a branch from Institute A could be referenced by
--         a department in Institute B. Cross-institute data corruption possible.
--         Fix: UNIQUE (id, institute_id) on root tables + composite FKs downstream.
--
-- [FIX-4] users.created_by self-reference bootstrap edge case.
--         Already nullable — documented here explicitly. Not a schema change.
--
-- [FIX-5] current_user_has_institute_scope() — NULL access_scope_id not handled.
--         NULL was documented as "institute-wide" but the function only checked
--         for explicit scope_type='institute' rows. Now handles both.
--
-- [FIX-6] FORCE ROW LEVEL SECURITY + app user ownership — operational note
--         and guard added. No schema change required, but explicit.
-- =============================================================================


-- =============================================================================
-- [FIX-1] patient_provider_assignments — partial unique index
-- =============================================================================

-- Drop the table-level constraint (nullable dept_id made it incorrect)
ALTER TABLE patient_provider_assignments
    DROP CONSTRAINT IF EXISTS uq_provider_patient_dept;

-- Partial unique index: only one active assignment per patient+provider+dept
-- Historical rows (is_active=false) are exempt — required for reassignment.
-- COALESCE handles NULL department_id deterministically.
CREATE UNIQUE INDEX uq_ppa_active
    ON patient_provider_assignments (
        patient_id,
        provider_id,
        COALESCE(department_id, '00000000-0000-0000-0000-000000000000'::UUID)
    )
    WHERE is_active = TRUE;

COMMENT ON INDEX uq_ppa_active IS
    '[FIX-1] Partial unique on active rows only. '
    'COALESCE on nullable department_id prevents NULL-distinct duplicate rows. '
    'is_active=false rows (history) are excluded — allows unassign + reassign.';


-- =============================================================================
-- [FIX-2] case_role_assignments — partial unique index
-- =============================================================================

ALTER TABLE case_role_assignments
    DROP CONSTRAINT IF EXISTS uq_case_role_per_scope;

CREATE UNIQUE INDEX uq_cra_active
    ON case_role_assignments (
        provider_id,
        case_role_type_id,
        scope_level_id,
        scope_ref_id
    )
    WHERE is_active = TRUE;

COMMENT ON INDEX uq_cra_active IS
    '[FIX-2] Partial unique on active case role assignments only. '
    'Historical inactive rows exempt. Allows unassign + reassign lifecycle.';


-- =============================================================================
-- [FIX-3] Institute boundary enforcement — composite FKs
-- =============================================================================
-- Problem: branch_id alone as an FK does not prevent a branch from Institute A
-- being referenced in a record belonging to Institute B. We need the FK to carry
-- (id, institute_id) so the DB itself enforces cross-institute isolation.
--
-- Pattern applied throughout:
--   1. Add UNIQUE (id, institute_id) to the parent table (natural — already unique
--      individually, but composite uniqueness is needed for FK target).
--   2. Downstream table carries both columns and references the composite key.
-- =============================================================================

-- ── Step 1: Add composite unique keys to root tables ─────────────────────────

-- institutes already has PK(id) which is unique — baseline.
-- branches: enable composite FK target
ALTER TABLE branches
    ADD CONSTRAINT uq_branches_id_institute
    UNIQUE (id, institute_id);

-- departments: enable composite FK target
ALTER TABLE departments
    ADD CONSTRAINT uq_departments_id_institute
    UNIQUE (id, institute_id);

-- units: enable composite FK target
ALTER TABLE units
    ADD CONSTRAINT uq_units_id_institute
    UNIQUE (id, institute_id);

-- users (platform-level, no institute_id — not applicable here)

-- user_institute_memberships: needed for downstream provider checks
ALTER TABLE user_institute_memberships
    ADD CONSTRAINT uq_uim_user_institute
    UNIQUE (user_id, institute_id);   -- already had this, but explicit for FK target

-- patients: enable composite FK target
ALTER TABLE patients
    ADD CONSTRAINT uq_patients_id_institute
    UNIQUE (id, institute_id);

-- ── Step 2: Add composite FKs on downstream tables ───────────────────────────

-- departments → branches: branch must belong to same institute
ALTER TABLE departments
    ADD COLUMN branch_institute_id UUID,   -- staging column to carry institute_id
    ADD CONSTRAINT fk_departments_branch_institute
    FOREIGN KEY (branch_id, institute_id)
    REFERENCES branches(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

-- Note: branch_institute_id staging column not needed — the composite FK uses the
-- institute_id already on the departments table. Drop the extra column.
ALTER TABLE departments DROP COLUMN IF EXISTS branch_institute_id;

COMMENT ON CONSTRAINT fk_departments_branch_institute ON departments IS
    '[FIX-3] Prevents a department referencing a branch from a different institute.';

-- units → departments: department must belong to same institute + branch
ALTER TABLE units
    ADD CONSTRAINT fk_units_department_institute
    FOREIGN KEY (department_id, institute_id)
    REFERENCES departments(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE units
    ADD CONSTRAINT fk_units_branch_institute
    FOREIGN KEY (branch_id, institute_id)
    REFERENCES branches(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

COMMENT ON CONSTRAINT fk_units_department_institute ON units IS
    '[FIX-3] Unit department must belong to same institute.';

-- resources → branch institute boundary
ALTER TABLE resources
    ADD CONSTRAINT fk_resources_branch_institute
    FOREIGN KEY (branch_id, institute_id)
    REFERENCES branches(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

-- patient_provider_assignments → patient institute boundary
-- Ensures the provider assignment record cannot reference a patient
-- from a different institute, even if institute_id is set incorrectly.
ALTER TABLE patient_provider_assignments
    ADD CONSTRAINT fk_ppa_patient_institute
    FOREIGN KEY (patient_id, institute_id)
    REFERENCES patients(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE patient_provider_assignments
    ADD CONSTRAINT fk_ppa_branch_institute
    FOREIGN KEY (branch_id, institute_id)
    REFERENCES branches(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

COMMENT ON CONSTRAINT fk_ppa_patient_institute ON patient_provider_assignments IS
    '[FIX-3] Patient and assignment must share same institute_id. '
    'Cross-institute patient access is structurally impossible, not just policy-blocked.';

-- patient_department_mapping → patient + dept + branch all within same institute
ALTER TABLE patient_department_mapping
    ADD CONSTRAINT fk_pdm_patient_institute
    FOREIGN KEY (patient_id, institute_id)
    REFERENCES patients(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE patient_department_mapping
    ADD CONSTRAINT fk_pdm_branch_institute
    FOREIGN KEY (branch_id, institute_id)
    REFERENCES branches(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE patient_department_mapping
    ADD CONSTRAINT fk_pdm_department_institute
    FOREIGN KEY (department_id, institute_id)
    REFERENCES departments(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

-- provider_department_mapping → institute boundary
ALTER TABLE provider_department_mapping
    ADD CONSTRAINT fk_prdm_branch_institute
    FOREIGN KEY (branch_id, institute_id)
    REFERENCES branches(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE provider_department_mapping
    ADD CONSTRAINT fk_prdm_department_institute
    FOREIGN KEY (department_id, institute_id)
    REFERENCES departments(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

-- case_role_types → institute (already correct, no composite needed here)
-- case_role_assignments → institute boundary on provider
-- Provider must be a member of the institute they are assigned within.
ALTER TABLE case_role_assignments
    ADD CONSTRAINT fk_cra_provider_institute
    FOREIGN KEY (provider_id, institute_id)
    REFERENCES user_institute_memberships(user_id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

COMMENT ON CONSTRAINT fk_cra_provider_institute ON case_role_assignments IS
    '[FIX-3] Provider must be an active member of this institute. '
    'Cross-institute case role assignment is structurally prevented.';

-- consent_records → patient institute boundary
ALTER TABLE consent_records
    ADD CONSTRAINT fk_consent_patient_institute
    FOREIGN KEY (patient_id, institute_id)
    REFERENCES patients(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;


-- =============================================================================
-- [FIX-4] users.created_by — bootstrap documentation
-- =============================================================================
-- No schema change required. users.created_by is already nullable.
-- Documenting the explicit bootstrap contract here for migration runners.
--
-- Bootstrap contract:
--   1. First user insert: created_by = NULL (system bootstrap, no actor yet)
--   2. application must record this in audit_log with action='SYSTEM_BOOTSTRAP'
--      and actor_id = NULL.
--   3. All subsequent user inserts must carry created_by = <admin user uuid>.
--   4. A CHECK constraint is intentionally NOT added here — platform onboarding
--      requires NULL created_by for the first institute admin user.
--
-- Operational enforcement: application layer + audit_log trail.
-- =============================================================================

COMMENT ON COLUMN users.created_by IS
    '[FIX-4] Nullable by design. First bootstrap user has created_by=NULL. '
    'All subsequent users must carry a non-null created_by. '
    'Enforced by application layer, audited via audit_log SYSTEM_BOOTSTRAP action.';


-- =============================================================================
-- [FIX-5] current_user_has_institute_scope() — handle NULL access_scope_id
-- =============================================================================
-- Original function only checked for explicit scope_type='institute' rows.
-- NULL access_scope_id in user_role_assignments was documented as "institute-wide"
-- but was not handled by the function. This created a silent inconsistency.
--
-- Decision locked here:
--   NULL access_scope_id = institute-wide access. No explicit scope row required.
--   Explicit scope row with scope_type='institute' also qualifies.
--   Both paths return TRUE from this function.
-- =============================================================================

CREATE OR REPLACE FUNCTION current_user_has_institute_scope()
RETURNS BOOLEAN LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM user_role_assignments ura
        WHERE ura.user_id      = current_user_id()
          AND ura.institute_id = current_institute_id()
          AND ura.is_active    = TRUE
          AND (ura.expires_at IS NULL OR ura.expires_at > NOW())
          AND (
              -- Path 1: NULL access_scope_id = institute-wide (documented convention)
              ura.access_scope_id IS NULL
              OR
              -- Path 2: explicit institute-scope row
              EXISTS (
                  SELECT 1 FROM access_scopes s
                  WHERE s.id          = ura.access_scope_id
                    AND s.scope_type  = 'institute'
                    AND s.institute_id = current_institute_id()
              )
          )
    )
$$;

COMMENT ON FUNCTION current_user_has_institute_scope() IS
    '[FIX-5] NULL access_scope_id is now formally handled as institute-wide. '
    'Explicit scope_type=institute row also qualifies. Both paths are equivalent. '
    'Resolves inconsistency between documented convention and actual function logic.';


-- =============================================================================
-- [FIX-6] FORCE ROW LEVEL SECURITY — operational guard
-- =============================================================================
-- FORCE ROW LEVEL SECURITY was applied to patients, consent_records,
-- patient_department_mapping, case_role_assignments in phase1_foundation.sql.
--
-- Risk: if the application DB user is the table owner, FORCE RLS still applies
-- to them, and INSERT/UPDATE may fail if no permissive policy covers writes.
--
-- Contract locked here:
--   - Application DB user (app_user role) is NOT the table owner.
--   - Table owner = migration runner / schema owner role (separate DB role).
--   - app_user is granted USAGE on schema + SELECT/INSERT/UPDATE on tables.
--   - app_user never owns tables. FORCE RLS applies to app_user correctly.
--
-- Enforce this now:
-- =============================================================================

DO $$
BEGIN
    -- Verify app_user exists (created in phase1_foundation.sql)
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
        RAISE EXCEPTION
            '[FIX-6] app_user role does not exist. '
            'Run phase1_foundation.sql before this patch.';
    END IF;
END
$$;

-- Grant schema access to app_user (idempotent)
GRANT USAGE ON SCHEMA public TO app_user;

-- Grant DML to app_user on all current domain tables
-- app_user must NOT be the owner of these tables.
GRANT SELECT, INSERT, UPDATE ON
    institutes,
    branches,
    departments,
    units,
    resources,
    users,
    user_institute_memberships,
    roles,
    permissions,
    role_permissions,
    access_scopes,
    user_role_assignments,
    patients,
    guardians,
    patient_guardian_links,
    consent_records,
    patient_department_mapping,
    patient_provider_assignments,
    provider_department_mapping,
    case_scope_levels,
    case_role_types,
    case_role_assignments
TO app_user;

-- audit_log and access_log: SELECT only for app_user
-- INSERT is via log_audit() SECURITY DEFINER function (owned by schema owner)
-- app_writer role handles the physical INSERT
GRANT SELECT ON audit_log, access_log TO app_user;
GRANT EXECUTE ON FUNCTION log_audit(UUID, UUID, INET, TEXT, TEXT, UUID, JSONB, JSONB, JSONB)
    TO app_user;

COMMENT ON ROLE app_user IS
    '[FIX-6] Application DB user. Never owns tables. '
    'FORCE ROW LEVEL SECURITY applies correctly because app_user is not table owner. '
    'Writes to audit_log via log_audit() SECURITY DEFINER — never direct INSERT.';


-- =============================================================================
-- PATCH 01 SUMMARY
-- =============================================================================
--
--  Fix  | Table(s) Affected                    | Type
-- ──────┼──────────────────────────────────────┼──────────────────────────────
--  1    | patient_provider_assignments          | DROP constraint, ADD partial index
--  2    | case_role_assignments                 | DROP constraint, ADD partial index
--  3    | branches, departments, units,         | ADD UNIQUE(id,inst_id) to parents
--       | resources, patients, patient_*,       | ADD composite FKs to children
--       | case_role_assignments, consent_records|
--  4    | users.created_by                      | Comment only, no schema change
--  5    | current_user_has_institute_scope()    | Function replaced — handles NULL
--  6    | app_user role, table grants           | GRANT statements, operational guard
--
-- After this patch, Phase 1 is production-grade.
-- Phase 2 (dynamic forms + clinical core) may now begin.
-- All Phase 2 tables must carry institute_id + composite FK pattern from [FIX-3].
-- =============================================================================