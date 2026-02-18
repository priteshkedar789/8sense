-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 1 — PATCH 02: FINAL STRUCTURAL HARDENING
-- =============================================================================
-- Apply after phase1_foundation.sql + phase1_patch01.sql
-- =============================================================================
--
-- CORRECTIONS IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-7] patient_provider_assignments missing composite FK to
--         user_institute_memberships. case_role_assignments had this; ppa did not.
--         Without it, a platform user could be assigned to a patient in an
--         institute they don't belong to. Row would exist; RLS would block access.
--         Structural integrity must precede policy enforcement.
--
-- [FIX-8] Active membership not enforced at structural level.
--         FK guarantees existence of membership row, NOT active state.
--         A terminated provider can satisfy the FK.
--         Fix: BEFORE INSERT/UPDATE trigger on both ppa and case_role_assignments
--         that validates membership_status='active' AND is_active=TRUE.
--
-- [NOTE-1] Polymorphic scope_ref_id on case_role_assignments has no FK enforcement.
--          This is a known gap, intentional now (program table doesn't exist yet).
--          Phase 2 MUST add a trigger enforcing referential integrity per scope_level.
--          Documented here so it cannot be forgotten.
--
-- [NOTE-2] current_user_has_permission() scope semantics clarified.
--          Function answers "does this user have this capability anywhere in this
--          institute?" — not "in the specific branch of this record."
--          This is CORRECT design. Scope visibility is enforced by RLS, not this
--          function. No code change — explicit documentation only.
-- =============================================================================


-- =============================================================================
-- [FIX-7] patient_provider_assignments — add missing provider institute FK
-- =============================================================================
-- Mirrors the FK already on case_role_assignments from Patch 01.
-- Closes the asymmetry: both assignment tables now structurally guarantee
-- the provider is a member of the institute before the row can exist.
-- =============================================================================

ALTER TABLE patient_provider_assignments
    ADD CONSTRAINT fk_ppa_provider_institute
    FOREIGN KEY (provider_id, institute_id)
    REFERENCES user_institute_memberships(user_id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

COMMENT ON CONSTRAINT fk_ppa_provider_institute ON patient_provider_assignments IS
    '[FIX-7] Provider must be a member of this institute. '
    'Cross-institute patient assignment is now structurally impossible. '
    'RLS blocks access; this FK prevents the row from existing at all.';


-- =============================================================================
-- [FIX-8] Active membership enforcement — trigger-based
-- =============================================================================
-- Problem: FK guarantees membership row exists. It does NOT guarantee:
--   membership_status = 'active' AND is_active = TRUE
-- A terminated or suspended provider satisfies the FK.
-- PostgreSQL does not allow subqueries in CHECK constraints.
-- Solution: BEFORE INSERT OR UPDATE trigger on both ppa and case_role_assignments.
-- =============================================================================

-- Shared validation function — called by both triggers
CREATE OR REPLACE FUNCTION validate_provider_active_membership()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_membership RECORD;
BEGIN
    SELECT is_active, membership_status
    INTO v_membership
    FROM user_institute_memberships
    WHERE user_id      = NEW.provider_id
      AND institute_id = NEW.institute_id;

    -- Membership row must exist (FK already enforces this, but defensive check)
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Provider % has no membership in institute %. '
            'Cannot create assignment.',
            NEW.provider_id, NEW.institute_id;
    END IF;

    -- Membership must be active — terminated/suspended providers cannot be assigned
    IF v_membership.is_active = FALSE OR v_membership.membership_status != 'active' THEN
        RAISE EXCEPTION
            'Provider % membership in institute % is not active (status: %, is_active: %). '
            'Resolve HR offboarding before modifying assignments.',
            NEW.provider_id, NEW.institute_id,
            v_membership.membership_status, v_membership.is_active;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION validate_provider_active_membership() IS
    '[FIX-8] Validates provider has active membership before INSERT or UPDATE. '
    'Called by triggers on patient_provider_assignments and case_role_assignments. '
    'Structural enforcement where FK alone is insufficient (FK checks existence, '
    'not state). HR offboarding immediately prevents new assignments.';

-- Trigger on patient_provider_assignments
CREATE TRIGGER trg_ppa_validate_active_membership
    BEFORE INSERT OR UPDATE OF provider_id, institute_id, is_active
    ON patient_provider_assignments
    FOR EACH ROW
    WHEN (NEW.is_active = TRUE)   -- Only validate on active assignment rows
    EXECUTE FUNCTION validate_provider_active_membership();

COMMENT ON TRIGGER trg_ppa_validate_active_membership
    ON patient_provider_assignments IS
    '[FIX-8] Fires on INSERT and on UPDATE when is_active becomes TRUE. '
    'Does not fire on deactivation (is_active=FALSE rows are historical).';

-- Trigger on case_role_assignments
CREATE TRIGGER trg_cra_validate_active_membership
    BEFORE INSERT OR UPDATE OF provider_id, institute_id, is_active
    ON case_role_assignments
    FOR EACH ROW
    WHEN (NEW.is_active = TRUE)
    EXECUTE FUNCTION validate_provider_active_membership();

COMMENT ON TRIGGER trg_cra_validate_active_membership
    ON case_role_assignments IS
    '[FIX-8] Same membership enforcement for clinical responsibility assignments. '
    'A terminated therapist cannot be assigned as primary_therapist on a case.';

-- ── What happens during HR offboarding ──────────────────────────────────────
-- When user_institute_memberships.membership_status is set to 'terminated':
--   1. Trigger blocks NEW assignments for this provider in this institute.
--   2. Existing active ppa and cra rows are NOT automatically deactivated
--      (intentional — clinical continuity must be explicitly handed over).
--   3. Application layer must run an offboarding workflow that:
--       a. Lists active ppa + cra rows for the provider
--       b. Requires explicit reassignment or case handover
--       c. Then sets is_active=FALSE on those rows
--       d. Logs all of the above to audit_log with action='PROVIDER_OFFBOARDED'
-- This is not enforced here — it is a workflow responsibility, not a DB constraint.
-- The trigger only blocks NEW assignments after termination.
-- ────────────────────────────────────────────────────────────────────────────


-- =============================================================================
-- [NOTE-1] Polymorphic scope_ref_id — Phase 2 obligation
-- =============================================================================
-- case_role_assignments.scope_ref_id is polymorphic:
--   scope_level = 'patient'    → should FK → patients(id)
--   scope_level = 'program'    → should FK → therapy_programs(id)   (Phase 2)
--   scope_level = 'department' → should FK → departments(id)
--
-- Current state: no FK on scope_ref_id. This is intentional — therapy_programs
-- does not exist yet. A premature FK would block Phase 2 migration ordering.
--
-- Phase 2 MUST add this trigger before any case_role_assignment with
-- scope_level='program' can be inserted:
--
--   CREATE OR REPLACE FUNCTION validate_case_role_scope_ref()
--   RETURNS TRIGGER LANGUAGE plpgsql AS $$
--   BEGIN
--       CASE NEW.scope_level_code   -- resolved via JOIN to case_scope_levels
--           WHEN 'patient' THEN
--               IF NOT EXISTS (SELECT 1 FROM patients WHERE id = NEW.scope_ref_id
--                              AND institute_id = NEW.institute_id) THEN
--                   RAISE EXCEPTION 'scope_ref_id % not found in patients', NEW.scope_ref_id;
--               END IF;
--           WHEN 'program' THEN
--               IF NOT EXISTS (SELECT 1 FROM therapy_programs WHERE id = NEW.scope_ref_id
--                              AND institute_id = NEW.institute_id) THEN
--                   RAISE EXCEPTION 'scope_ref_id % not found in therapy_programs', NEW.scope_ref_id;
--               END IF;
--           WHEN 'department' THEN
--               IF NOT EXISTS (SELECT 1 FROM departments WHERE id = NEW.scope_ref_id
--                              AND institute_id = NEW.institute_id) THEN
--                   RAISE EXCEPTION 'scope_ref_id % not found in departments', NEW.scope_ref_id;
--               END IF;
--       END CASE;
--       RETURN NEW;
--   END;
--   $$;
--
-- Department scope_ref_id CAN be enforced now. Adding it:
-- =============================================================================

-- Enforce department scope_ref_id immediately (department table exists)
CREATE OR REPLACE FUNCTION validate_case_role_scope_ref_partial()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_scope_code TEXT;
BEGIN
    SELECT code INTO v_scope_code
    FROM case_scope_levels
    WHERE id = NEW.scope_level_id;

    IF v_scope_code = 'patient' THEN
        IF NOT EXISTS (
            SELECT 1 FROM patients
            WHERE id = NEW.scope_ref_id
              AND institute_id = NEW.institute_id
        ) THEN
            RAISE EXCEPTION
                'scope_ref_id % not found in patients for institute %',
                NEW.scope_ref_id, NEW.institute_id;
        END IF;

    ELSIF v_scope_code = 'department' THEN
        IF NOT EXISTS (
            SELECT 1 FROM departments
            WHERE id = NEW.scope_ref_id
              AND institute_id = NEW.institute_id
        ) THEN
            RAISE EXCEPTION
                'scope_ref_id % not found in departments for institute %',
                NEW.scope_ref_id, NEW.institute_id;
        END IF;

    ELSIF v_scope_code = 'program' THEN
        -- therapy_programs table does not exist yet (Phase 2)
        -- Blocked at application layer until Phase 2 migration completes.
        RAISE EXCEPTION
            'scope_level=program is not yet supported. '
            'therapy_programs table will be created in Phase 2. '
            'Do not insert program-scoped case role assignments until Phase 2 migration is applied.';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cra_validate_scope_ref
    BEFORE INSERT OR UPDATE OF scope_level_id, scope_ref_id
    ON case_role_assignments
    FOR EACH ROW
    EXECUTE FUNCTION validate_case_role_scope_ref_partial();

COMMENT ON TRIGGER trg_cra_validate_scope_ref ON case_role_assignments IS
    '[NOTE-1] Partial polymorphic FK enforcement. '
    'patient + department scope validated now. '
    'program scope blocked until Phase 2 therapy_programs table exists. '
    'Phase 2 must replace this function with full three-way validation.';


-- =============================================================================
-- [NOTE-2] current_user_has_permission() semantics — clarification only
-- =============================================================================
-- No code change. Replacing the comment on the function to make semantics
-- unambiguous for every developer who reads this schema.
-- =============================================================================

COMMENT ON FUNCTION current_user_has_permission(TEXT) IS
    '[NOTE-2] SEMANTICS: answers "does this user hold a role with this permission '
    'ANYWHERE within the current institute?" '
    'It does NOT check whether the permission applies to the specific branch '
    'or department of the record being accessed. '
    'Scope narrowing (branch/dept restriction) is handled by RLS policies '
    'via patient_provider_assignments and access_scopes. '
    'This function is a capability gate, not a visibility gate. '
    'Both checks are required and neither replaces the other.';


-- =============================================================================
-- PATCH 02 SUMMARY
-- =============================================================================
--
--  Fix     | What Changed
-- ─────────┼────────────────────────────────────────────────────────────────
--  FIX-7   | ADD CONSTRAINT fk_ppa_provider_institute on ppa
--           | Closes FK asymmetry between ppa and case_role_assignments
--
--  FIX-8   | validate_provider_active_membership() function
--           | trg_ppa_validate_active_membership trigger on ppa
--           | trg_cra_validate_active_membership trigger on cra
--           | Structural guard: terminated providers cannot be assigned
--           | Historical inactive rows unaffected
--
--  NOTE-1  | validate_case_role_scope_ref_partial() function
--           | trg_cra_validate_scope_ref trigger on case_role_assignments
--           | patient + department scope_ref_id validated now
--           | program scope blocked with explicit error until Phase 2
--
--  NOTE-2  | Comment on current_user_has_permission() — semantics only
--           | Capability gate vs visibility gate distinction documented
--
-- =============================================================================
-- PHASE 1 STATUS AFTER PATCH 02
-- =============================================================================
--
--  Layer                          | Status
-- ────────────────────────────────┼──────────────────────────────────────────
--  Multi-tenancy boundary         | Structurally enforced
--  Cross-institute corruption     | Prevented at DB level
--  Assignment uniqueness          | Partial index — correct lifecycle model
--  Historical rows                | Preserved
--  RLS anchor                     | patient_provider_assignments
--  Institute scope resolution     | NULL + explicit row, both handled
--  Audit immutability             | REVOKE + trigger
--  Privilege separation           | app_user ≠ table owner
--  Platform admin bypass          | Isolated, explicit
--  Provider membership existence  | FK enforced
--  Provider membership active     | Trigger enforced
--  HR offboarding block           | New assignments blocked (existing = workflow)
--  Polymorphic FK (patient/dept)  | Trigger enforced
--  Polymorphic FK (program)       | Phase 2 obligation, blocked with error
--
-- Phase 1 is now production-grade enterprise infrastructure.
-- Phase 2 (Dynamic Form Engine + Clinical Core) may now begin.
-- =============================================================================