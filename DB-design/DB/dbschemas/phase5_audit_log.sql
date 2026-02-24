-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 5 — AUDIT LOG INFRASTRUCTURE
-- =============================================================================
-- Apply after: all Phase 1, 2, 3, and 4 files
-- No schema changes to existing tables. No cross-dependencies.
-- =============================================================================
--
-- LOCKED DECISIONS
-- ─────────────────────────────────────────────────────────────────────────────
-- [D-AL1] UPDATE only. INSERT is self-audited (created_at + created_by).
--         DELETE is structurally blocked on all governance tables.
-- [D-AL2] Full OLD + NEW JSONB snapshot (not status-only).
--         DPDP requirement: "what changed, when, by whom?"
--         Pre-submission edits + trigger-driven mutations both captured.
-- [D-AL3] Only when OLD IS DISTINCT FROM NEW.
--         updated_at-only changes suppressed as noise.
-- [D-AL4] Append-only tables excluded (wallet_transactions, payments).
--         Audit logging immutable ledgers is redundant.
-- [D-AL5] Same transaction as business write. Audit failure = write rollback.
-- [D-AL6] SECURITY DEFINER to capture trigger-driven mutations
--         (insurance_authorizations.sessions_used, patient_wallets.balance).
--
-- TABLE SCOPE (8 tables):
--   Clinical:  form_responses, session_records, evaluations, plan_change_requests
--   Financial: billing_charges, invoices, insurance_authorizations, patient_wallets
-- =============================================================================


-- =============================================================================
-- SECTION 1 — AUDIT LOG TABLE
-- =============================================================================

CREATE TABLE audit_log (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id    UUID,       -- NULL for system-level mutations
    table_name      TEXT        NOT NULL,
    row_id          UUID        NOT NULL,
    operation       TEXT        NOT NULL DEFAULT 'UPDATE',
    old_data        JSONB       NOT NULL,
    new_data        JSONB       NOT NULL,
    changed_fields  TEXT[],     -- column names that actually changed
    changed_by      UUID,       -- app.current_user_id session variable
    session_info    JSONB,      -- application context (role, request_id, ip)
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE audit_log IS
    'Immutable audit trail for high-governance tables. '
    'Captures UPDATE operations where OLD IS DISTINCT FROM NEW. '
    'INSERT excluded (self-audited via created_at + created_by on every table). '
    'DELETE excluded (structurally blocked on all governance tables). '
    'old_data + new_data: full row snapshot as JSONB. '
    'changed_fields: columns that changed — used by GIN index for field-level queries. '
    'session_info: application context from app.* session variables. '
    'This table is itself append-only.';

CREATE INDEX idx_al_table_row      ON audit_log(table_name, row_id);
CREATE INDEX idx_al_changed_at     ON audit_log(changed_at DESC);
CREATE INDEX idx_al_institute      ON audit_log(institute_id, changed_at DESC)
    WHERE institute_id IS NOT NULL;
CREATE INDEX idx_al_changed_by     ON audit_log(changed_by, changed_at DESC)
    WHERE changed_by IS NOT NULL;
CREATE INDEX idx_al_table_date     ON audit_log(table_name, changed_at DESC);
CREATE INDEX idx_al_new_data       ON audit_log USING gin(new_data);
CREATE INDEX idx_al_changed_fields ON audit_log USING gin(changed_fields);

-- Audit log itself is append-only
CREATE OR REPLACE FUNCTION enforce_audit_log_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is an immutable record. Row % cannot be modified or deleted.', OLD.id;
END;
$$;

CREATE TRIGGER trg_audit_log_immutable
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION enforce_audit_log_immutability();

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;

CREATE POLICY al_platform_admin ON audit_log FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY al_institute_read ON audit_log FOR SELECT USING (
    institute_id = current_institute_id()
    AND current_user_has_permission('CAN_VIEW_AUDIT_LOG')
);
-- Trigger function inserts: unrestricted (SECURITY DEFINER handles auth)
CREATE POLICY al_insert ON audit_log FOR INSERT WITH CHECK (TRUE);


-- =============================================================================
-- SECTION 2 — GENERIC AUDIT TRIGGER FUNCTION
-- =============================================================================
-- One function attached to all 8 tables.
-- AFTER UPDATE — fires after all business logic triggers complete.
-- SECURITY DEFINER — captures trigger-driven mutations outside user context.
-- Does NOT modify NEW. Does NOT interfere with business logic.
-- =============================================================================

CREATE OR REPLACE FUNCTION capture_audit_log()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_old_json      JSONB;
    v_new_json      JSONB;
    v_changed       TEXT[];
    v_key           TEXT;
    v_institute_id  UUID;
    v_changed_by    UUID;
    v_session_info  JSONB;
BEGIN
    v_old_json := to_jsonb(OLD);
    v_new_json := to_jsonb(NEW);

    -- [D-AL3] Suppress no-op updates
    IF v_old_json = v_new_json THEN RETURN NULL; END IF;

    -- Compute changed fields
    v_changed := ARRAY[]::TEXT[];
    FOR v_key IN SELECT jsonb_object_keys(v_new_json) LOOP
        IF v_new_json -> v_key IS DISTINCT FROM v_old_json -> v_key THEN
            v_changed := array_append(v_changed, v_key);
        END IF;
    END LOOP;

    -- Suppress updated_at-only changes (timestamp noise)
    IF v_changed = ARRAY['updated_at'] THEN RETURN NULL; END IF;

    -- Extract institute_id from row if present
    v_institute_id := NULLIF((v_new_json ->> 'institute_id'), '')::UUID;

    -- Resolve changed_by from application session variable
    BEGIN
        v_changed_by := current_setting('app.current_user_id', TRUE)::UUID;
    EXCEPTION WHEN OTHERS THEN
        v_changed_by := NULL;
    END;

    -- Capture application context
    BEGIN
        v_session_info := jsonb_build_object(
            'app_role',    current_setting('app.current_role',   TRUE),
            'request_id',  current_setting('app.request_id',     TRUE),
            'ip_address',  current_setting('app.client_ip',      TRUE),
            'pg_user',     current_user
        );
    EXCEPTION WHEN OTHERS THEN
        v_session_info := jsonb_build_object('pg_user', current_user);
    END;

    INSERT INTO audit_log (
        institute_id, table_name, row_id, operation,
        old_data, new_data, changed_fields,
        changed_by, session_info
    ) VALUES (
        v_institute_id,
        TG_TABLE_NAME,
        (v_new_json ->> 'id')::UUID,
        TG_OP,
        v_old_json,
        v_new_json,
        v_changed,
        v_changed_by,
        v_session_info
    );

    RETURN NULL;  -- AFTER trigger, return value unused
END;
$$;

COMMENT ON FUNCTION capture_audit_log() IS
    'Generic AFTER UPDATE audit trigger. Attached to 8 high-governance tables. '
    'SECURITY DEFINER: captures mutations from business logic triggers '
    '  (patient_wallets.balance, insurance_authorizations.sessions_used). '
    'AFTER trigger: fires after all BEFORE triggers — captures final committed state. '
    'Suppresses: no-op updates, updated_at-only changes. '
    'changed_fields: array of column names that changed (used by GIN index). '
    'session_info: reads app.current_user_id, app.current_role, app.request_id, '
    '  app.client_ip. Application must SET these at transaction start. '
    'Falls back to pg current_user if session variables absent. '
    'Same transaction as write [D-AL5]: audit failure = write rollback.';


-- =============================================================================
-- SECTION 3 — ATTACH TRIGGERS TO HIGH-GOVERNANCE TABLES
-- =============================================================================

-- Clinical: form_responses
CREATE TRIGGER trg_audit_form_responses
    AFTER UPDATE ON form_responses
    FOR EACH ROW EXECUTE FUNCTION capture_audit_log();

COMMENT ON TRIGGER trg_audit_form_responses ON form_responses IS
    'Audit: submission lifecycle (draft→submitted→reviewed→locked), '
    'pre-submission field edits, note_status changes.';

-- Clinical: session_records
CREATE TRIGGER trg_audit_session_records
    AFTER UPDATE ON session_records
    FOR EACH ROW EXECUTE FUNCTION capture_audit_log();

COMMENT ON TRIGGER trg_audit_session_records ON session_records IS
    'Audit: dual-domain freeze transitions (status + note_status), '
    'clinical documentation changes, session completion.';

-- Clinical: evaluations
CREATE TRIGGER trg_audit_evaluations
    AFTER UPDATE ON evaluations
    FOR EACH ROW EXECUTE FUNCTION capture_audit_log();

COMMENT ON TRIGGER trg_audit_evaluations ON evaluations IS
    'Audit: evaluation lifecycle (draft→submitted→reviewed→locked), '
    'interpretive_score changes, instrument submission gate.';

-- Clinical: plan_change_requests
CREATE TRIGGER trg_audit_plan_change_requests
    AFTER UPDATE ON plan_change_requests
    FOR EACH ROW EXECUTE FUNCTION capture_audit_log();

COMMENT ON TRIGGER trg_audit_plan_change_requests ON plan_change_requests IS
    'Audit: PCR lifecycle (draft→submitted→approved→implemented|rejected), '
    'resulting_version_id assignment on implementation.';

-- Financial: billing_charges
CREATE TRIGGER trg_audit_billing_charges
    AFTER UPDATE ON billing_charges
    FOR EACH ROW EXECUTE FUNCTION capture_audit_log();

COMMENT ON TRIGGER trg_audit_billing_charges ON billing_charges IS
    'Audit: charge_status transitions, wallet_applied_amount changes '
    '(trigger-driven from charge creation), advancement to paid.';

-- Financial: invoices
CREATE TRIGGER trg_audit_invoices
    AFTER UPDATE ON invoices
    FOR EACH ROW EXECUTE FUNCTION capture_audit_log();

COMMENT ON TRIGGER trg_audit_invoices ON invoices IS
    'Audit: invoice_status transitions, total_amount and paid_amount '
    'recalculations (trigger-driven), issuance and settlement.';

-- Financial: insurance_authorizations
CREATE TRIGGER trg_audit_insurance_authorizations
    AFTER UPDATE ON insurance_authorizations
    FOR EACH ROW EXECUTE FUNCTION capture_audit_log();

COMMENT ON TRIGGER trg_audit_insurance_authorizations ON insurance_authorizations IS
    'Audit: sessions_used increments (trigger-driven, invisible to user layer), '
    'auth activation/deactivation, validity window changes. '
    'SECURITY DEFINER ensures capture despite trigger execution context.';

-- Financial: patient_wallets
CREATE TRIGGER trg_audit_patient_wallets
    AFTER UPDATE ON patient_wallets
    FOR EACH ROW EXECUTE FUNCTION capture_audit_log();

COMMENT ON TRIGGER trg_audit_patient_wallets ON patient_wallets IS
    'Audit: balance changes (trigger-driven from create_charge_on_session_completion), '
    'total_debited accumulation. No direct user writes to this table — '
    'all mutations are trigger-driven. SECURITY DEFINER is essential here.';


-- =============================================================================
-- SECTION 4 — AUDIT QUERY HELPERS
-- =============================================================================

-- Full chronological history of a row
CREATE OR REPLACE FUNCTION audit_history(
    p_table_name    TEXT,
    p_row_id        UUID
)
RETURNS TABLE (
    changed_at      TIMESTAMPTZ,
    changed_by      UUID,
    changed_fields  TEXT[],
    old_data        JSONB,
    new_data        JSONB,
    session_info    JSONB
) LANGUAGE SQL STABLE SECURITY DEFINER AS $$
    SELECT changed_at, changed_by, changed_fields, old_data, new_data, session_info
    FROM audit_log
    WHERE table_name = p_table_name
      AND row_id     = p_row_id
    ORDER BY changed_at ASC;
$$;

COMMENT ON FUNCTION audit_history(TEXT, UUID) IS
    'Full chronological change history for a specific row. '
    'Usage: SELECT * FROM audit_history(''session_records'', ''<uuid>'');';

-- Table changes within a time window
CREATE OR REPLACE FUNCTION audit_table_window(
    p_table_name    TEXT,
    p_from          TIMESTAMPTZ,
    p_to            TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
    changed_at      TIMESTAMPTZ,
    row_id          UUID,
    changed_by      UUID,
    changed_fields  TEXT[],
    old_data        JSONB,
    new_data        JSONB
) LANGUAGE SQL STABLE SECURITY DEFINER AS $$
    SELECT changed_at, row_id, changed_by, changed_fields, old_data, new_data
    FROM audit_log
    WHERE table_name = p_table_name
      AND changed_at BETWEEN p_from AND p_to
    ORDER BY changed_at DESC;
$$;

-- All changes by a specific user
CREATE OR REPLACE FUNCTION audit_by_user(
    p_user_id       UUID,
    p_from          TIMESTAMPTZ DEFAULT NOW() - INTERVAL '30 days',
    p_to            TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
    changed_at      TIMESTAMPTZ,
    table_name      TEXT,
    row_id          UUID,
    changed_fields  TEXT[],
    new_data        JSONB
) LANGUAGE SQL STABLE SECURITY DEFINER AS $$
    SELECT changed_at, table_name, row_id, changed_fields, new_data
    FROM audit_log
    WHERE changed_by = p_user_id
      AND changed_at BETWEEN p_from AND p_to
    ORDER BY changed_at DESC;
$$;

-- All transitions of a specific field across a table
-- e.g. all status transitions, all balance changes
CREATE OR REPLACE FUNCTION audit_field_transitions(
    p_table_name    TEXT,
    p_field         TEXT,
    p_from          TIMESTAMPTZ DEFAULT NOW() - INTERVAL '30 days',
    p_to            TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
    changed_at      TIMESTAMPTZ,
    row_id          UUID,
    changed_by      UUID,
    old_value       TEXT,
    new_value       TEXT
) LANGUAGE SQL STABLE SECURITY DEFINER AS $$
    SELECT
        changed_at,
        row_id,
        changed_by,
        old_data ->> p_field AS old_value,
        new_data ->> p_field AS new_value
    FROM audit_log
    WHERE table_name  = p_table_name
      AND p_field     = ANY(changed_fields)
      AND changed_at  BETWEEN p_from AND p_to
    ORDER BY changed_at DESC;
$$;

COMMENT ON FUNCTION audit_field_transitions(TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) IS
    'All transitions of a specific field across a table within a time window. '
    'Usage: SELECT * FROM audit_field_transitions(''session_records'', ''status'', now()-interval ''7 days''); '
    'Uses GIN index on changed_fields for efficient filtering. '
    'Practical examples: '
    '  Status lifecycle: audit_field_transitions(''invoices'', ''invoice_status'', ...) '
    '  Balance changes:  audit_field_transitions(''patient_wallets'', ''balance'', ...) '
    '  Auth depletion:   audit_field_transitions(''insurance_authorizations'', ''sessions_used'', ...)';


-- =============================================================================
-- SECTION 5 — APPLICATION LAYER CONTRACT
-- =============================================================================
-- The audit trigger reads these session variables from the application layer.
-- Application must SET these at the start of each transaction:
--
--   SET LOCAL app.current_user_id = '<uuid>';
--   SET LOCAL app.current_role    = 'clinician';
--   SET LOCAL app.request_id      = '<request-uuid>';
--   SET LOCAL app.client_ip       = '<ip-address>';
--
-- SET LOCAL ensures variables are transaction-scoped (reset on commit/rollback).
-- If not set: pg_user (PostgreSQL role) is used as fallback.
-- This is the same pattern used by RLS helper functions (current_user_id()).
-- =============================================================================

COMMENT ON TABLE audit_log IS
    'Immutable audit trail for high-governance tables. '
    'APPLICATION CONTRACT: SET LOCAL app.current_user_id, app.current_role, '
    '  app.request_id, app.client_ip at transaction start. '
    'Fallback: pg current_user if session variables not set. '
    'Captures UPDATE operations where OLD IS DISTINCT FROM NEW. '
    'SUPPRESSED: no-op updates, updated_at-only changes. '
    'INCLUDED: all other field changes including trigger-driven mutations. '
    'AFTER trigger positioning: captures final committed state after all '
    '  BEFORE triggers (lifecycle, freeze, immutability) have executed.';


-- =============================================================================
-- PERMISSIONS
-- =============================================================================

INSERT INTO permissions (code, name, module, description) VALUES
    ('CAN_VIEW_AUDIT_LOG', 'View Audit Log', 'governance',
        'Read the audit trail for high-governance tables within own institute')
ON CONFLICT (code) DO NOTHING;


-- =============================================================================
-- PHASE 5 AUDIT LOG — COMPLETE INVENTORY
-- =============================================================================
--
-- Table:
--   audit_log                            append-only, JSONB snapshots
--
-- Indexes (7):
--   (table_name, row_id)                 primary row lookup
--   (changed_at DESC)                    time-range queries
--   (institute_id, changed_at)           institute-scoped queries
--   (changed_by, changed_at)             user activity queries
--   (table_name, changed_at)             table-scoped queries
--   GIN(new_data)                        JSONB field-value queries
--   GIN(changed_fields)                  field-name array queries
--
-- Trigger function:
--   capture_audit_log()                  generic AFTER UPDATE, SECURITY DEFINER
--
-- Trigger attachments (8):
--   trg_audit_form_responses
--   trg_audit_session_records
--   trg_audit_evaluations
--   trg_audit_plan_change_requests
--   trg_audit_billing_charges
--   trg_audit_invoices
--   trg_audit_insurance_authorizations
--   trg_audit_patient_wallets
--
-- Query helpers (4):
--   audit_history(table, row_id)
--   audit_table_window(table, from, to)
--   audit_by_user(user_id, from, to)
--   audit_field_transitions(table, field, from, to)
--
-- =============================================================================
-- SUPPRESSION LOGIC
-- =============================================================================
--   OLD = NEW              → suppressed (no-op update)
--   changed = [updated_at] → suppressed (timestamp noise)
--   all other changes      → captured (including trigger-driven mutations)
--
-- =============================================================================
-- PHASE 5 REMAINING
-- =============================================================================
--   phase5_audit_log.sql      ← this file
--   phase5_reporting.sql      — materialized views:
--                               AR aging, provider utilisation, attendance
--                               variance, wallet liability, auth depletion
--   phase5_room_capacity.sql  — EXCLUSION constraints on rooms + schedule_blocks
-- =============================================================================
