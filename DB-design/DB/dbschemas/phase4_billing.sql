-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 4 — BILLING SUBSYSTEM
-- =============================================================================
-- Apply after: phase4_scheduling.sql
-- =============================================================================
--
-- LOCKED DECISIONS
-- ─────────────────────────────────────────────────────────────────────────────
-- [D-B1] Charge creation: session_records.status → 'completed' (same transaction)
--        Clinical event finalizes → financial event immediately follows.
--        Waiting for note submission would couple financial truth to documentation.
--
-- [D-B2] Session amendment after charge: manual billing adjustment only.
--        Clinical amendment (Phase 3 supersedes chain) remains independent.
--        Finance creates credit + adjustment charges manually.
--        No trigger chains across clinical and financial layers.
--
-- [D-B3] Wallet deduction: same transaction as charge creation (auto-deduct).
--        Guarantees atomic integrity — no double-spend race, no stale balance.
--        Insufficient balance: convert remainder to invoice receivable (not block).
--        Clinical delivery is never blocked by wallet balance.
--
-- [D-B4] Pricing: most-specific-wins (patient contract > program > institute default).
--        Rate stamped at charge creation — never recomputed from pricing tables.
--        Duration variance is clinical documentation — billing is flat per session.
--
-- [D-B5] Insurance: authorization tracking only (India reimbursement model).
--        Parent pays clinic → parent claims from insurer → no adjudication lifecycle.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- BILLING ARCHITECTURE
-- ─────────────────────────────────────────────────────────────────────────────
--   institute_billing_models    — per-institute billing mode configuration
--   institute_pricing           — effective-dated base rates by therapy type
--   program_pricing             — program-level rate overrides
--   patient_pricing_contracts   — patient-level negotiated rate overrides
--   insurance_authorizations    — auth tracking (sessions approved/used)
--   billing_charges             — immutable stamped-rate financial events
--   patient_wallets             — advance payment balance
--   wallet_transactions         — append-only wallet ledger
--   invoices                    — parent-facing billing documents
--   invoice_line_items          — charge → invoice linkage
--   payments                    — append-only payment receipt records
--   payment_allocations         — payment → invoice linkage
-- =============================================================================


-- =============================================================================
-- SECTION 1 — INSTITUTE BILLING MODELS
-- =============================================================================

CREATE TABLE institute_billing_models (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id    UUID        NOT NULL REFERENCES institutes(id),
    billing_mode    TEXT        NOT NULL,
        -- 'session_based'   — charge per completed session
        -- 'advance_wallet'  — prepaid balance, auto-deducted at session completion
        -- 'one_time_fee'    — single program fee at program activation
        -- 'hybrid'          — program-level override determines mode
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    effective_from  DATE        NOT NULL DEFAULT CURRENT_DATE,
    effective_to    DATE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_ibm_institute_mode UNIQUE (institute_id, billing_mode),
    CONSTRAINT chk_ibm_mode CHECK (billing_mode IN ('session_based','advance_wallet','one_time_fee','hybrid')),
    CONSTRAINT chk_ibm_date_order CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

COMMENT ON TABLE institute_billing_models IS
    'Per-institute billing mode configuration. Multiple modes may be active '
    '(e.g., session_based + advance_wallet). '
    'Program-level override determines mode per program when hybrid is active. '
    'Effective-dated: future mode changes can be pre-configured.';

CREATE INDEX idx_ibm_institute ON institute_billing_models(institute_id) WHERE is_active = TRUE;

ALTER TABLE institute_billing_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE institute_billing_models FORCE ROW LEVEL SECURITY;
CREATE POLICY ibm_platform_admin ON institute_billing_models FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY ibm_read  ON institute_billing_models FOR SELECT USING (institute_id = current_institute_id());
CREATE POLICY ibm_admin ON institute_billing_models FOR ALL USING (
    institute_id = current_institute_id() AND current_user_has_institute_scope()
    AND current_user_has_permission('CAN_MANAGE_BILLING')
);


-- =============================================================================
-- SECTION 2 — PRICING TABLES (effective-dated, three tiers)
-- =============================================================================

-- Tier 1: Institute default rates by therapy type
CREATE TABLE institute_pricing (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id    UUID        NOT NULL REFERENCES institutes(id),
    therapy_type_id UUID        NOT NULL REFERENCES therapy_type_registry(id),
    service_type    TEXT        NOT NULL DEFAULT 'session',
        -- 'session','evaluation','program_fee','group_session'
    rate_amount     NUMERIC(10,2) NOT NULL,
    currency        TEXT        NOT NULL DEFAULT 'INR',
    effective_from  DATE        NOT NULL,
    effective_to    DATE,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES users(id),

    CONSTRAINT chk_ip_rate_positive CHECK (rate_amount >= 0),
    CONSTRAINT chk_ip_date_order    CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

COMMENT ON TABLE institute_pricing IS
    'Tier 1 (lowest priority) in pricing resolution. '
    'Institute default rate by therapy type and service type. '
    'Rate is effective-dated — future price changes pre-configurable. '
    'Charge creation reads the rate active on session.actual_start date. '
    'Historical charges retain their stamped rate regardless of future changes.';

CREATE INDEX idx_ip_institute   ON institute_pricing(institute_id);
CREATE INDEX idx_ip_active      ON institute_pricing(institute_id, therapy_type_id, effective_from)
    WHERE is_active = TRUE;

-- Tier 2: Program-level rate overrides
CREATE TABLE program_pricing (
    id                  UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID        NOT NULL REFERENCES institutes(id),
    therapy_program_id  UUID        NOT NULL REFERENCES therapy_programs(id),
    service_type        TEXT        NOT NULL DEFAULT 'session',
    rate_amount         NUMERIC(10,2) NOT NULL,
    currency            TEXT        NOT NULL DEFAULT 'INR',
    effective_from      DATE        NOT NULL,
    effective_to        DATE,
    is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by          UUID        REFERENCES users(id),

    CONSTRAINT fk_pp_program_institute
        FOREIGN KEY (therapy_program_id, institute_id)
        REFERENCES therapy_programs(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_pp_rate_positive CHECK (rate_amount >= 0),
    CONSTRAINT chk_pp_date_order    CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

COMMENT ON TABLE program_pricing IS
    'Tier 2 in pricing resolution. Overrides institute_pricing for a specific program. '
    'Intensive ABA programs may have different rates from standard ABA. '
    'If no program_pricing active on session date → falls through to institute_pricing.';

CREATE INDEX idx_pp_program  ON program_pricing(therapy_program_id) WHERE is_active = TRUE;

-- Tier 3: Patient contract overrides (highest priority)
CREATE TABLE patient_pricing_contracts (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id    UUID        NOT NULL REFERENCES institutes(id),
    patient_id      UUID        NOT NULL REFERENCES patients(id),
    therapy_type_id UUID        REFERENCES therapy_type_registry(id),
        -- NULL = applies to all therapy types for this patient
    service_type    TEXT        NOT NULL DEFAULT 'session',
    rate_amount     NUMERIC(10,2) NOT NULL,
    currency        TEXT        NOT NULL DEFAULT 'INR',
    contract_reason TEXT        NOT NULL,
        -- 'financial_hardship','research_participant','legacy_contract','staff_family'
    effective_from  DATE        NOT NULL,
    effective_to    DATE        NOT NULL,   -- contracts always have end date
    approved_by     UUID        NOT NULL REFERENCES users(id),
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_ppc_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_ppc_rate_positive  CHECK (rate_amount >= 0),
    CONSTRAINT chk_ppc_date_order     CHECK (effective_to >= effective_from)
);

COMMENT ON TABLE patient_pricing_contracts IS
    'Tier 3 (highest priority) in pricing resolution. '
    'Patient-level negotiated rate — financial hardship, research, legacy contracts. '
    'therapy_type_id nullable: NULL applies to all session types for this patient. '
    'Specific type contract takes precedence over NULL-type contract. '
    'Must have end date (contracts are time-bounded by governance policy). '
    'approved_by required — no self-approved discounts.';

CREATE INDEX idx_ppc_patient   ON patient_pricing_contracts(patient_id, effective_from)
    WHERE is_active = TRUE;


-- =============================================================================
-- SECTION 3 — INSURANCE AUTHORIZATION TRACKING (non-claim model)
-- =============================================================================

CREATE TABLE insurance_authorizations (
    id                      UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id            UUID        NOT NULL REFERENCES institutes(id),
    patient_id              UUID        NOT NULL REFERENCES patients(id),
    therapy_program_id      UUID        REFERENCES therapy_programs(id),

    -- Authorization details
    insurer_name            TEXT        NOT NULL,
    policy_number           TEXT        NOT NULL,
    policy_holder_name      TEXT,
    auth_code               TEXT        NOT NULL,
    therapy_type_id         UUID        REFERENCES therapy_type_registry(id),

    -- Session limits
    sessions_approved       INTEGER     NOT NULL,
    sessions_used           INTEGER     NOT NULL DEFAULT 0,
    sessions_remaining      INTEGER
        GENERATED ALWAYS AS (sessions_approved - sessions_used) STORED,

    -- Validity
    valid_from              DATE        NOT NULL,
    valid_to                DATE        NOT NULL,
    is_active               BOOLEAN     NOT NULL DEFAULT TRUE,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_ia_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_ia_dates             CHECK (valid_to >= valid_from),
    CONSTRAINT chk_ia_sessions_positive CHECK (sessions_approved > 0),
    CONSTRAINT chk_ia_sessions_used     CHECK (sessions_used >= 0),
    CONSTRAINT chk_ia_not_overused      CHECK (sessions_used <= sessions_approved),

    CONSTRAINT uq_ia_id_institute UNIQUE (id, institute_id)
);

COMMENT ON TABLE insurance_authorizations IS
    'Insurance authorization tracking — India reimbursement model. '
    'Clinic receives payment from parent; parent submits invoice to insurer for reimbursement. '
    'This table tracks whether a session falls within an authorized window. '
    'No claim lifecycle, no remittance, no adjudication — that is external to this system. '
    'sessions_used incremented by charge creation trigger (FOR UPDATE lock, concurrency-safe). '
    'Insurance-eligible charges are flagged with insurance_authorization_id on billing_charges.';

CREATE INDEX idx_ia_patient   ON insurance_authorizations(patient_id, valid_from)
    WHERE is_active = TRUE;
CREATE INDEX idx_ia_institute ON insurance_authorizations(institute_id);

ALTER TABLE insurance_authorizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE insurance_authorizations FORCE ROW LEVEL SECURITY;
CREATE POLICY ia_platform_admin ON insurance_authorizations FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY ia_read ON insurance_authorizations FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR current_user_assigned_to_patient(patient_id))
);
CREATE POLICY ia_write ON insurance_authorizations FOR ALL USING (
    institute_id = current_institute_id()
    AND current_user_has_institute_scope()
    AND current_user_has_permission('CAN_MANAGE_BILLING')
);


-- =============================================================================
-- SECTION 4 — RATE RESOLUTION FUNCTION
-- =============================================================================
-- Deterministic, testable, isolated. Called by charge creation trigger.
-- Resolution order: patient contract → program rate → institute default.
-- If no rate found: raises exception (pricing misconfiguration is explicit).
-- =============================================================================

CREATE OR REPLACE FUNCTION resolve_session_rate(
    p_session_id    UUID
)
RETURNS TABLE (
    rate_amount     NUMERIC(10,2),
    rate_source     TEXT,           -- 'patient_contract','program_rate','institute_default'
    currency        TEXT
) LANGUAGE plpgsql AS $$
DECLARE
    v_session           session_records%ROWTYPE;
    v_session_date      DATE;
    v_rate              NUMERIC(10,2);
    v_source            TEXT;
    v_currency          TEXT;
BEGIN
    SELECT * INTO v_session FROM session_records WHERE id = p_session_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'resolve_session_rate: session % not found.', p_session_id;
    END IF;

    v_session_date := v_session.actual_start::DATE;

    -- Tier 3: Patient contract (most specific wins)
    -- Specific therapy_type contract takes precedence over NULL-type contract
    SELECT ppc.rate_amount, 'patient_contract', ppc.currency
    INTO v_rate, v_source, v_currency
    FROM patient_pricing_contracts ppc
    WHERE ppc.patient_id    = v_session.patient_id
      AND ppc.institute_id  = v_session.institute_id
      AND ppc.service_type  = 'session'
      AND ppc.is_active     = TRUE
      AND ppc.effective_from <= v_session_date
      AND ppc.effective_to  >= v_session_date
      AND (ppc.therapy_type_id = v_session.therapy_type_id OR ppc.therapy_type_id IS NULL)
    ORDER BY ppc.therapy_type_id NULLS LAST   -- specific type before NULL-type
    LIMIT 1;

    IF FOUND THEN RETURN QUERY SELECT v_rate, v_source, v_currency; RETURN; END IF;

    -- Tier 2: Program-level override
    IF v_session.therapy_program_id IS NOT NULL THEN
        SELECT pp.rate_amount, 'program_rate', pp.currency
        INTO v_rate, v_source, v_currency
        FROM program_pricing pp
        WHERE pp.therapy_program_id = v_session.therapy_program_id
          AND pp.institute_id       = v_session.institute_id
          AND pp.service_type       = 'session'
          AND pp.is_active          = TRUE
          AND pp.effective_from    <= v_session_date
          AND (pp.effective_to IS NULL OR pp.effective_to >= v_session_date)
        ORDER BY pp.effective_from DESC
        LIMIT 1;

        IF FOUND THEN RETURN QUERY SELECT v_rate, v_source, v_currency; RETURN; END IF;
    END IF;

    -- Tier 1: Institute default
    SELECT ip.rate_amount, 'institute_default', ip.currency
    INTO v_rate, v_source, v_currency
    FROM institute_pricing ip
    WHERE ip.institute_id    = v_session.institute_id
      AND ip.therapy_type_id = v_session.therapy_type_id
      AND ip.service_type    = 'session'
      AND ip.is_active       = TRUE
      AND ip.effective_from <= v_session_date
      AND (ip.effective_to IS NULL OR ip.effective_to >= v_session_date)
    ORDER BY ip.effective_from DESC
    LIMIT 1;

    IF FOUND THEN RETURN QUERY SELECT v_rate, v_source, v_currency; RETURN; END IF;

    -- No rate found: pricing misconfiguration
    RAISE EXCEPTION
        'resolve_session_rate: no active pricing found for session % '
        '(patient=%, therapy_type=%, institute=%, date=%). '
        'Configure institute_pricing for this therapy type before sessions can be billed.',
        p_session_id, v_session.patient_id, v_session.therapy_type_id,
        v_session.institute_id, v_session_date;
END;
$$;

COMMENT ON FUNCTION resolve_session_rate(UUID) IS
    'Deterministic rate resolution: patient_contract > program_rate > institute_default. '
    'Returns (rate_amount, rate_source, currency). '
    'Raises exception if no pricing configured — misconfiguration is explicit, not silent zero. '
    'Reads rates effective on session.actual_start::DATE. '
    'Isolated function — can be tested independently of charge creation trigger.';


-- =============================================================================
-- SECTION 5 — BILLING CHARGES (immutable financial events)
-- =============================================================================

CREATE TABLE billing_charges (
    id                          UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id                UUID        NOT NULL REFERENCES institutes(id),
    patient_id                  UUID        NOT NULL REFERENCES patients(id),

    -- Source event
    source_type                 TEXT        NOT NULL,
        -- 'session','evaluation','program_fee','manual_credit','manual_adjustment'
    source_id                   UUID,       -- session_records.id, evaluations.id, etc.

    -- Stamped rate (immutable at creation)
    therapy_type_id             UUID        REFERENCES therapy_type_registry(id),
    resolved_rate               NUMERIC(10,2) NOT NULL,
    rate_source                 TEXT        NOT NULL,
        -- 'patient_contract','program_rate','institute_default','manual'
    amount                      NUMERIC(10,2) NOT NULL,
    currency                    TEXT        NOT NULL DEFAULT 'INR',

    -- Insurance eligibility
    insurance_authorization_id  UUID        REFERENCES insurance_authorizations(id),
    is_insurance_eligible       BOOLEAN     NOT NULL DEFAULT FALSE,

    -- Charge lifecycle
    charge_status               TEXT        NOT NULL DEFAULT 'pending',
        -- 'pending' → 'invoiced' → 'paid' | 'voided' | 'written_off'

    -- Billing model used for this charge
    billing_model               TEXT        NOT NULL,
        -- 'session_based','advance_wallet','one_time_fee'

    -- Wallet deduction tracking
    wallet_transaction_id       UUID,       -- set if charge covered by wallet (FK added below)

    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by                  UUID        REFERENCES users(id),

    -- ── Integrity ─────────────────────────────────────────────────────────────
    CONSTRAINT fk_bc_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_bc_amount_positive    CHECK (amount >= 0),
    CONSTRAINT chk_bc_resolved_positive  CHECK (resolved_rate >= 0),
    CONSTRAINT chk_bc_status             CHECK (charge_status IN ('pending','invoiced','paid','voided','written_off')),

    -- One charge per session (structural idempotency guarantee [D-B1])
    CONSTRAINT uq_bc_session_charge
        UNIQUE (source_type, source_id)
        WHERE source_type IN ('session','evaluation'),

    CONSTRAINT uq_bc_id_institute UNIQUE (id, institute_id)
);

COMMENT ON TABLE billing_charges IS
    'Immutable financial event record. Created atomically at session completion. '
    'resolved_rate and rate_source stamped at creation — never recomputed. '
    'uq_bc_session_charge: one charge per session (structural idempotency). '
    'Charge is immutable once charge_status = invoiced. '
    'Corrections via manual_credit or manual_adjustment charges — never edit. '
    'insurance_authorization_id: set if session falls within active authorization window. '
    'wallet_transaction_id: set if charge covered by advance wallet deduction.';

CREATE INDEX idx_bc_patient         ON billing_charges(patient_id);
CREATE INDEX idx_bc_institute       ON billing_charges(institute_id);
CREATE INDEX idx_bc_status          ON billing_charges(institute_id, charge_status);
CREATE INDEX idx_bc_source          ON billing_charges(source_type, source_id);
CREATE INDEX idx_bc_insurance       ON billing_charges(insurance_authorization_id)
    WHERE insurance_authorization_id IS NOT NULL;

-- Charge immutability: frozen once invoiced
CREATE OR REPLACE FUNCTION enforce_charge_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.charge_status IN ('invoiced','paid','voided','written_off') THEN
        IF NEW.resolved_rate  IS DISTINCT FROM OLD.resolved_rate   OR
           NEW.rate_source    IS DISTINCT FROM OLD.rate_source     OR
           NEW.amount         IS DISTINCT FROM OLD.amount          OR
           NEW.patient_id     IS DISTINCT FROM OLD.patient_id      OR
           NEW.source_id      IS DISTINCT FROM OLD.source_id       OR
           NEW.source_type    IS DISTINCT FROM OLD.source_type
        THEN
            RAISE EXCEPTION
                'billing_charge % (status=%) is frozen. '
                'Core financial fields cannot change after invoicing. '
                'Create a manual_credit or manual_adjustment charge for corrections.',
                OLD.id, OLD.charge_status;
        END IF;
    END IF;

    -- Status progression: forward-only
    IF OLD.charge_status = 'pending'  AND NEW.charge_status NOT IN ('pending','invoiced','voided') THEN
        RAISE EXCEPTION 'charge %: invalid transition pending → %.', OLD.id, NEW.charge_status;
    END IF;
    IF OLD.charge_status = 'invoiced' AND NEW.charge_status NOT IN ('invoiced','paid','written_off') THEN
        RAISE EXCEPTION 'charge %: invalid transition invoiced → %.', OLD.id, NEW.charge_status;
    END IF;
    IF OLD.charge_status IN ('paid','voided','written_off') THEN
        RAISE EXCEPTION 'charge %: status=% is terminal.', OLD.id, OLD.charge_status;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_charge_immutability
    BEFORE UPDATE ON billing_charges
    FOR EACH ROW EXECUTE FUNCTION enforce_charge_immutability();

ALTER TABLE billing_charges ENABLE ROW LEVEL SECURITY;
ALTER TABLE billing_charges FORCE ROW LEVEL SECURITY;
CREATE POLICY bc_platform_admin ON billing_charges FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY bc_read ON billing_charges FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR current_user_assigned_to_patient(patient_id)
         OR current_user_has_permission('CAN_VIEW_BILLING'))
);
CREATE POLICY bc_insert ON billing_charges FOR INSERT WITH CHECK (
    institute_id = current_institute_id()
);
CREATE POLICY bc_status_update ON billing_charges FOR UPDATE
    USING  (institute_id = current_institute_id() AND current_user_has_permission('CAN_MANAGE_BILLING'))
    WITH CHECK (institute_id = current_institute_id() AND current_user_has_permission('CAN_MANAGE_BILLING'));


-- =============================================================================
-- SECTION 6 — PATIENT WALLETS + WALLET TRANSACTIONS
-- =============================================================================

CREATE TABLE patient_wallets (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id    UUID        NOT NULL REFERENCES institutes(id),
    patient_id      UUID        NOT NULL REFERENCES patients(id),
    currency        TEXT        NOT NULL DEFAULT 'INR',
    balance         NUMERIC(10,2) NOT NULL DEFAULT 0,
    credit_balance  NUMERIC(10,2) NOT NULL DEFAULT 0,  -- advance payments received
    total_debited   NUMERIC(10,2) NOT NULL DEFAULT 0,  -- cumulative session deductions
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_wallet_patient_institute UNIQUE (patient_id, institute_id),

    CONSTRAINT fk_wallet_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- Balance can be negative only if institute policy allows (handled in trigger)
    CONSTRAINT chk_wallet_credit_nonneg CHECK (credit_balance >= 0)
);

COMMENT ON TABLE patient_wallets IS
    'Advance payment wallet per patient per institute. '
    'balance = available for deduction. '
    'credit_balance = total advance payments received (audit running total). '
    'total_debited = cumulative session charges deducted (audit running total). '
    'Insufficient balance: remainder converted to receivable (not blocking). '
    'wallet_transactions is the append-only ledger — wallet row is the summary.';

CREATE TABLE wallet_transactions (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    wallet_id       UUID        NOT NULL REFERENCES patient_wallets(id),
    institute_id    UUID        NOT NULL REFERENCES institutes(id),
    transaction_type TEXT       NOT NULL,
        -- 'credit'      — advance payment received
        -- 'debit'       — session charge deducted
        -- 'refund'      — refund to patient
        -- 'adjustment'  — manual correction
    amount          NUMERIC(10,2) NOT NULL,
    balance_after   NUMERIC(10,2) NOT NULL,  -- wallet balance after this transaction
    reference_id    UUID,       -- billing_charge.id (debit), payment.id (credit/refund)
    reference_type  TEXT,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES users(id),

    CONSTRAINT chk_wt_amount_positive CHECK (amount > 0),
    CONSTRAINT chk_wt_type CHECK (transaction_type IN ('credit','debit','refund','adjustment'))
);

-- Append-only wallet transactions
CREATE OR REPLACE FUNCTION enforce_wallet_transaction_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'wallet_transaction % is an immutable ledger entry.', OLD.id;
END;
$$;

CREATE TRIGGER trg_wt_immutable
    BEFORE UPDATE OR DELETE ON wallet_transactions
    FOR EACH ROW EXECUTE FUNCTION enforce_wallet_transaction_immutability();

-- Add FK from billing_charges to wallet_transactions (table now exists)
ALTER TABLE billing_charges
    ADD CONSTRAINT fk_bc_wallet_transaction
    FOREIGN KEY (wallet_transaction_id)
    REFERENCES wallet_transactions(id);

CREATE INDEX idx_wt_wallet    ON wallet_transactions(wallet_id);
CREATE INDEX idx_wt_reference ON wallet_transactions(reference_type, reference_id);

ALTER TABLE patient_wallets    ENABLE ROW LEVEL SECURITY;
ALTER TABLE patient_wallets    FORCE ROW LEVEL SECURITY;
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_transactions FORCE ROW LEVEL SECURITY;

CREATE POLICY pw_platform_admin ON patient_wallets FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY pw_read ON patient_wallets FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR current_user_assigned_to_patient(patient_id)
         OR current_user_has_permission('CAN_VIEW_BILLING'))
);
CREATE POLICY pw_admin ON patient_wallets FOR ALL USING (
    institute_id = current_institute_id() AND current_user_has_permission('CAN_MANAGE_BILLING')
);
CREATE POLICY wt_platform_admin ON wallet_transactions FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY wt_read ON wallet_transactions FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR current_user_has_permission('CAN_VIEW_BILLING'))
);
CREATE POLICY wt_insert ON wallet_transactions FOR INSERT WITH CHECK (
    institute_id = current_institute_id()
);


-- =============================================================================
-- SECTION 7 — CHARGE CREATION TRIGGER (fires at session completion)
-- =============================================================================
-- THE CORE BILLING TRIGGER.
-- Fires: session_records.status transitions in_progress → completed
-- Actions:
--   1. resolve_session_rate() — deterministic rate lookup
--   2. Check insurance authorization (optional, non-blocking)
--   3. Create billing_charge (stamped rate, immutable)
--   4. If advance_wallet model: auto-deduct wallet, create wallet_transaction
--      If insufficient: charge remainder amount, wallet goes to 0 (not negative)
-- =============================================================================

CREATE OR REPLACE FUNCTION create_charge_on_session_completion()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_billing_mode      TEXT;
    v_rate              NUMERIC(10,2);
    v_rate_source       TEXT;
    v_currency          TEXT;
    v_charge_id         UUID;
    v_auth_id           UUID;
    v_wallet_id         UUID;
    v_wallet_balance    NUMERIC(10,2);
    v_deduct_amount     NUMERIC(10,2);
    v_remainder         NUMERIC(10,2);
    v_wt_id             UUID;
BEGIN
    -- Only fire on in_progress → completed transition
    IF NOT (OLD.status = 'in_progress' AND NEW.status = 'completed') THEN
        RETURN NEW;
    END IF;

    -- ── 1. Resolve billing mode for this institute ────────────────────────────
    SELECT billing_mode INTO v_billing_mode
    FROM institute_billing_models
    WHERE institute_id = NEW.institute_id
      AND is_active    = TRUE
      AND effective_from <= CURRENT_DATE
      AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
    ORDER BY effective_from DESC
    LIMIT 1;

    -- If no billing model configured: skip charge creation (institute not yet set up for billing)
    IF v_billing_mode IS NULL THEN
        RETURN NEW;
    END IF;

    -- one_time_fee sessions do not generate per-session charges
    IF v_billing_mode = 'one_time_fee' THEN
        RETURN NEW;
    END IF;

    -- ── 2. Resolve rate ────────────────────────────────────────────────────────
    SELECT r.rate_amount, r.rate_source, r.currency
    INTO v_rate, v_rate_source, v_currency
    FROM resolve_session_rate(NEW.id) r;

    -- ── 3. Check insurance authorization (non-blocking, FOR UPDATE) ────────────
    SELECT ia.id INTO v_auth_id
    FROM insurance_authorizations ia
    WHERE ia.patient_id         = NEW.patient_id
      AND ia.institute_id       = NEW.institute_id
      AND ia.is_active          = TRUE
      AND ia.sessions_remaining > 0
      AND ia.valid_from        <= NEW.actual_start::DATE
      AND ia.valid_to          >= NEW.actual_start::DATE
      AND (ia.therapy_type_id  = NEW.therapy_type_id OR ia.therapy_type_id IS NULL)
    ORDER BY ia.therapy_type_id NULLS LAST, ia.valid_to ASC
    LIMIT 1
    FOR UPDATE;   -- concurrency-safe sessions_used increment

    IF v_auth_id IS NOT NULL THEN
        UPDATE insurance_authorizations
        SET sessions_used = sessions_used + 1, updated_at = NOW()
        WHERE id = v_auth_id;
    END IF;

    -- ── 4. Create the charge ──────────────────────────────────────────────────
    v_charge_id := generate_uuidv7();

    INSERT INTO billing_charges (
        id, institute_id, patient_id,
        source_type, source_id,
        therapy_type_id, resolved_rate, rate_source, amount, currency,
        insurance_authorization_id, is_insurance_eligible,
        charge_status, billing_model
    ) VALUES (
        v_charge_id,
        NEW.institute_id, NEW.patient_id,
        'session', NEW.id,
        NEW.therapy_type_id, v_rate, v_rate_source, v_rate, v_currency,
        v_auth_id, (v_auth_id IS NOT NULL),
        'pending', v_billing_mode
    );

    -- ── 5. Wallet deduction (advance_wallet model only) ───────────────────────
    IF v_billing_mode = 'advance_wallet' THEN

        SELECT id, balance INTO v_wallet_id, v_wallet_balance
        FROM patient_wallets
        WHERE patient_id   = NEW.patient_id
          AND institute_id = NEW.institute_id
          AND is_active    = TRUE
        FOR UPDATE;  -- prevents concurrent deductions from racing

        IF v_wallet_id IS NOT NULL AND v_wallet_balance > 0 THEN
            -- Deduct available balance (up to full charge amount)
            v_deduct_amount := LEAST(v_wallet_balance, v_rate);
            v_remainder     := v_rate - v_deduct_amount;

            v_wt_id := generate_uuidv7();

            -- Create wallet debit transaction
            INSERT INTO wallet_transactions (
                id, wallet_id, institute_id,
                transaction_type, amount, balance_after,
                reference_id, reference_type, notes
            ) VALUES (
                v_wt_id, v_wallet_id, NEW.institute_id,
                'debit', v_deduct_amount, v_wallet_balance - v_deduct_amount,
                v_charge_id, 'billing_charge',
                CASE WHEN v_remainder > 0
                     THEN 'Partial wallet deduction — remainder ' || v_currency || ' ' || v_remainder || ' converted to receivable'
                     ELSE 'Full wallet deduction'
                END
            );

            -- Update wallet balance
            UPDATE patient_wallets
            SET balance       = balance - v_deduct_amount,
                total_debited = total_debited + v_deduct_amount,
                updated_at    = NOW()
            WHERE id = v_wallet_id;

            -- Link wallet transaction to charge
            UPDATE billing_charges
            SET wallet_transaction_id = v_wt_id,
                amount = v_remainder  -- outstanding amount after wallet deduction
            WHERE id = v_charge_id;
        END IF;
        -- If wallet balance = 0 or no wallet: full charge remains as receivable
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_session_charge_creation
    BEFORE UPDATE OF status ON session_records
    FOR EACH ROW EXECUTE FUNCTION create_charge_on_session_completion();

COMMENT ON TRIGGER trg_session_charge_creation ON session_records IS
    '[D-B1] Charge created atomically at session completion. '
    '[D-B3] Wallet deduction in same transaction — FOR UPDATE prevents race. '
    'Insufficient wallet: deducts available balance, remainder stays as receivable. '
    'Clinical delivery is never blocked by wallet state. '
    'Insurance auth incremented with FOR UPDATE (concurrency-safe). '
    'If no billing model configured: charge creation skipped silently. '
    'uq_bc_session_charge ensures idempotency — retry-safe.';


-- =============================================================================
-- SECTION 8 — INVOICES + LINE ITEMS
-- =============================================================================

CREATE SEQUENCE invoice_number_seq START 1000 INCREMENT 1;

CREATE TABLE invoices (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id    UUID        NOT NULL REFERENCES institutes(id),
    patient_id      UUID        NOT NULL REFERENCES patients(id),
    invoice_number  TEXT        NOT NULL,   -- human-readable, institute-scoped
    billing_period_start DATE   NOT NULL,
    billing_period_end   DATE   NOT NULL,
    total_amount    NUMERIC(10,2) NOT NULL DEFAULT 0,
    paid_amount     NUMERIC(10,2) NOT NULL DEFAULT 0,
    outstanding_amount NUMERIC(10,2)
        GENERATED ALWAYS AS (total_amount - paid_amount) STORED,
    currency        TEXT        NOT NULL DEFAULT 'INR',
    invoice_status  TEXT        NOT NULL DEFAULT 'draft',
        -- 'draft' → 'issued' → 'paid' | 'partially_paid' | 'cancelled'
    issued_at       TIMESTAMPTZ,
    paid_at         TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES users(id),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_invoice_number    UNIQUE (institute_id, invoice_number),
    CONSTRAINT chk_invoice_status   CHECK (invoice_status IN ('draft','issued','paid','partially_paid','cancelled')),
    CONSTRAINT chk_invoice_period   CHECK (billing_period_end >= billing_period_start),
    CONSTRAINT chk_invoice_issued_at CHECK (invoice_status = 'draft' OR issued_at IS NOT NULL),

    CONSTRAINT fk_invoice_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT uq_invoice_id_institute UNIQUE (id, institute_id)
);

-- Invoice number generation (FOR UPDATE on sequence avoids races)
CREATE OR REPLACE FUNCTION generate_invoice_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_seq   BIGINT;
    v_prefix TEXT;
BEGIN
    -- Prefix: INV-{YYYY}-{institute short code}
    -- For simplicity: INV-YYYY-NNNNNN
    v_seq    := nextval('invoice_number_seq');
    v_prefix := 'INV-' || TO_CHAR(NOW(), 'YYYY') || '-';
    NEW.invoice_number := v_prefix || LPAD(v_seq::TEXT, 6, '0');
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_invoice_number
    BEFORE INSERT ON invoices
    FOR EACH ROW
    WHEN (NEW.invoice_number IS NULL OR NEW.invoice_number = '')
    EXECUTE FUNCTION generate_invoice_number();

-- Invoice freeze + lifecycle
CREATE OR REPLACE FUNCTION enforce_invoice_lifecycle()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Lifecycle transitions
    IF NEW.invoice_status != OLD.invoice_status THEN
        IF OLD.invoice_status = 'draft'    AND NEW.invoice_status NOT IN ('draft','issued','cancelled') THEN
            RAISE EXCEPTION 'invoice %: invalid transition draft → %.', OLD.id, NEW.invoice_status;
        END IF;
        IF OLD.invoice_status = 'issued'   AND NEW.invoice_status NOT IN ('issued','paid','partially_paid','cancelled') THEN
            RAISE EXCEPTION 'invoice %: invalid transition issued → %.', OLD.id, NEW.invoice_status;
        END IF;
        IF OLD.invoice_status = 'partially_paid' AND NEW.invoice_status NOT IN ('partially_paid','paid','cancelled') THEN
            RAISE EXCEPTION 'invoice %: invalid transition partially_paid → %.', OLD.id, NEW.invoice_status;
        END IF;
        IF OLD.invoice_status IN ('paid','cancelled') THEN
            RAISE EXCEPTION 'invoice %: status=% is terminal.', OLD.id, OLD.invoice_status;
        END IF;
    END IF;

    -- Content freeze: once issued, amounts and patient cannot change
    IF OLD.invoice_status IN ('issued','paid','partially_paid') THEN
        IF NEW.patient_id       IS DISTINCT FROM OLD.patient_id   OR
           NEW.total_amount     IS DISTINCT FROM OLD.total_amount  OR
           NEW.currency         IS DISTINCT FROM OLD.currency
        THEN
            RAISE EXCEPTION 'invoice % (status=%) is frozen — core fields cannot change.', OLD.id, OLD.invoice_status;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_invoice_lifecycle
    BEFORE UPDATE ON invoices
    FOR EACH ROW EXECUTE FUNCTION enforce_invoice_lifecycle();

CREATE TABLE invoice_line_items (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    invoice_id      UUID        NOT NULL REFERENCES invoices(id),
    institute_id    UUID        NOT NULL REFERENCES institutes(id),
    charge_id       UUID        NOT NULL REFERENCES billing_charges(id),
    description     TEXT        NOT NULL,
    amount          NUMERIC(10,2) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_ili_charge UNIQUE (charge_id),   -- one charge per invoice line
    CONSTRAINT fk_ili_invoice_institute
        FOREIGN KEY (invoice_id, institute_id)
        REFERENCES invoices(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED
);

-- Line items frozen once invoice issued
CREATE OR REPLACE FUNCTION enforce_line_item_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_status TEXT;
BEGIN
    SELECT invoice_status INTO v_status FROM invoices WHERE id = COALESCE(OLD.invoice_id, NEW.invoice_id);
    IF v_status IN ('issued','paid','partially_paid') THEN
        RAISE EXCEPTION 'invoice % is issued — line items cannot be modified or deleted.', COALESCE(OLD.invoice_id, NEW.invoice_id);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_line_item_immutable
    BEFORE UPDATE OR DELETE ON invoice_line_items
    FOR EACH ROW EXECUTE FUNCTION enforce_line_item_immutability();

CREATE INDEX idx_inv_patient  ON invoices(patient_id);
CREATE INDEX idx_inv_institute ON invoices(institute_id, invoice_status);
CREATE INDEX idx_ili_invoice  ON invoice_line_items(invoice_id);

ALTER TABLE invoices           ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices           FORCE ROW LEVEL SECURITY;
ALTER TABLE invoice_line_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoice_line_items FORCE ROW LEVEL SECURITY;

CREATE POLICY inv_platform_admin ON invoices FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY inv_read  ON invoices FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR current_user_assigned_to_patient(patient_id)
         OR current_user_has_permission('CAN_VIEW_BILLING'))
);
CREATE POLICY inv_write ON invoices FOR ALL USING (
    institute_id = current_institute_id() AND current_user_has_permission('CAN_MANAGE_BILLING')
);
CREATE POLICY ili_platform_admin ON invoice_line_items FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY ili_read  ON invoice_line_items FOR SELECT USING (institute_id = current_institute_id());
CREATE POLICY ili_write ON invoice_line_items FOR INSERT WITH CHECK (
    institute_id = current_institute_id() AND current_user_has_permission('CAN_MANAGE_BILLING')
);


-- =============================================================================
-- SECTION 9 — PAYMENTS (append-only)
-- =============================================================================

CREATE TABLE payments (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id    UUID        NOT NULL REFERENCES institutes(id),
    patient_id      UUID        NOT NULL REFERENCES patients(id),
    amount          NUMERIC(10,2) NOT NULL,
    currency        TEXT        NOT NULL DEFAULT 'INR',
    payment_method  TEXT        NOT NULL,
        -- 'cash','upi','card','bank_transfer','cheque'
    payment_date    DATE        NOT NULL DEFAULT CURRENT_DATE,
    reference_number TEXT,      -- UPI ref, card txn id, cheque number, etc.
    notes           TEXT,
    received_by     UUID        REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_payment_amount   CHECK (amount > 0),
    CONSTRAINT chk_payment_method   CHECK (payment_method IN ('cash','upi','card','bank_transfer','cheque')),

    CONSTRAINT fk_payment_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT uq_payment_id_institute UNIQUE (id, institute_id)
);

COMMENT ON TABLE payments IS
    'Append-only payment receipt records. '
    'Records money received by clinic from parent. '
    'Insurance reimbursement is parent-to-insurer — not modeled here (India model). '
    'payment_allocations links payments to invoices.';

CREATE OR REPLACE FUNCTION enforce_payment_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'payment % is an immutable receipt record.', OLD.id;
END;
$$;

CREATE TRIGGER trg_payment_immutable
    BEFORE UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION enforce_payment_immutability();

CREATE TABLE payment_allocations (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    payment_id      UUID        NOT NULL REFERENCES payments(id),
    invoice_id      UUID        NOT NULL REFERENCES invoices(id),
    institute_id    UUID        NOT NULL REFERENCES institutes(id),
    allocated_amount NUMERIC(10,2) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_pa_payment_invoice UNIQUE (payment_id, invoice_id),
    CONSTRAINT chk_pa_amount_positive CHECK (allocated_amount > 0)
);

CREATE OR REPLACE FUNCTION enforce_allocation_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'payment_allocation % is immutable.', OLD.id;
END;
$$;

CREATE TRIGGER trg_allocation_immutable
    BEFORE UPDATE OR DELETE ON payment_allocations
    FOR EACH ROW EXECUTE FUNCTION enforce_allocation_immutability();

CREATE INDEX idx_pay_patient    ON payments(patient_id);
CREATE INDEX idx_pay_institute  ON payments(institute_id, payment_date DESC);
CREATE INDEX idx_palloc_payment ON payment_allocations(payment_id);
CREATE INDEX idx_palloc_invoice ON payment_allocations(invoice_id);

ALTER TABLE payments            ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments            FORCE ROW LEVEL SECURITY;
ALTER TABLE payment_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_allocations FORCE ROW LEVEL SECURITY;

CREATE POLICY pay_platform_admin ON payments FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY pay_read  ON payments FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR current_user_has_permission('CAN_VIEW_BILLING'))
);
CREATE POLICY pay_insert ON payments FOR INSERT WITH CHECK (
    institute_id = current_institute_id() AND current_user_has_permission('CAN_MANAGE_BILLING')
);
CREATE POLICY pa_platform_admin ON payment_allocations FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY pa_read   ON payment_allocations FOR SELECT USING (institute_id = current_institute_id());
CREATE POLICY pa_insert ON payment_allocations FOR INSERT WITH CHECK (
    institute_id = current_institute_id() AND current_user_has_permission('CAN_MANAGE_BILLING')
);


-- =============================================================================
-- PERMISSIONS SEED
-- =============================================================================
INSERT INTO permissions (code, name, module, description) VALUES
    ('CAN_VIEW_BILLING',    'View Billing',      'billing', 'View charges, invoices, payment history'),
    ('CAN_MANAGE_BILLING',  'Manage Billing',    'billing', 'Create invoices, record payments, manage pricing'),
    ('CAN_MANAGE_PRICING',  'Manage Pricing',    'billing', 'Configure institute and program pricing tables')
ON CONFLICT (code) DO NOTHING;


-- =============================================================================
-- PHASE 4 BILLING — INVENTORY
-- =============================================================================
--
-- Tables (12):
--   institute_billing_models         per-institute billing mode config
--   institute_pricing                tier 1 rates (effective-dated)
--   program_pricing                  tier 2 overrides (effective-dated)
--   patient_pricing_contracts        tier 3 overrides (effective-dated)
--   insurance_authorizations         auth tracking (sessions approved/used)
--   billing_charges                  immutable stamped-rate financial events
--   patient_wallets                  advance payment balance
--   wallet_transactions              append-only wallet ledger
--   invoices                         parent-facing billing documents
--   invoice_line_items               charge → invoice linkage
--   payments                         append-only payment receipts
--   payment_allocations              payment → invoice linkage
--
-- Function:
--   resolve_session_rate(UUID)       deterministic 3-tier pricing resolution
--
-- Key triggers:
--   trg_session_charge_creation      session completion → charge + wallet deduction
--   trg_charge_immutability          charge frozen post-invoice + forward-only status
--   trg_invoice_lifecycle            invoice forward-only + content freeze at issued
--   trg_line_item_immutable          line items frozen when invoice issued
--   trg_payment_immutable / trg_allocation_immutable   append-only enforcement
--   trg_wt_immutable                 wallet ledger append-only
--
-- Freeze semantics (billing layer):
--   billing_charges   → frozen at charge_status = invoiced
--   invoices          → frozen at invoice_status = issued
--   payments          → append-only (never frozen, never modified)
--   wallet_transactions → append-only
--   payment_allocations → append-only
--
-- =============================================================================
-- PHASE 4 COMPLETE MIGRATION SEQUENCE
-- =============================================================================
--   phase4_scheduling.sql    (capacity-based block model)
--   phase4_billing.sql       (multi-model billing engine)   ← this file
-- =============================================================================
