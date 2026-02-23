-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 4 — BILLING PATCH 01: STRUCTURAL HARDENING
-- =============================================================================
-- Apply after: phase4_billing.sql
-- =============================================================================
--
-- FIXES IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-B1] Billing mode resolution made program-aware.
--          Previous model selected one billing mode from institute_billing_models
--          with ORDER BY effective_from DESC LIMIT 1 — non-deterministic when
--          multiple modes are active. Fix: therapy_programs.billing_model_override
--          column added. Trigger reads program override first, falls back to
--          institute default. Hybrid mode is now structurally meaningful.
--
-- [FIX-B2] billing_charges.amount must not be mutated post-creation.
--          Wallet deduction is a settlement layer, not a charge mutation.
--          Fix: add wallet_applied_amount column and generated outstanding_amount.
--          Trigger now writes wallet_applied_amount instead of overwriting amount.
--          amount always = resolved_rate (full charge). Immutable.
--
-- [FIX-B3] Invoice total_amount and paid_amount must auto-recalculate.
--          Invoices were static containers — line item inserts and payment
--          allocations had no corresponding aggregate update.
--          Fix: triggers on invoice_line_items and payment_allocations
--          recalculate invoice.total_amount and invoice.paid_amount atomically.
--
-- BONUS [FIX-B4] Insurance authorization non-overlap constraint.
--          Reviewer noted overlapping authorizations for same therapy type
--          are possible. Fix: trigger blocks overlapping active authorizations
--          for the same patient + therapy type + institute combination.
-- =============================================================================


-- =============================================================================
-- [FIX-B1] Program-aware billing mode resolution
-- =============================================================================

-- Add billing_model_override to therapy_programs
ALTER TABLE therapy_programs
    ADD COLUMN IF NOT EXISTS billing_model_override TEXT,
    ADD CONSTRAINT chk_tp_billing_override
        CHECK (billing_model_override IS NULL OR
               billing_model_override IN ('session_based','advance_wallet','one_time_fee'));

COMMENT ON COLUMN therapy_programs.billing_model_override IS
    '[FIX-B1] Per-program billing mode. Overrides institute_billing_models when set. '
    'NULL: inherit institute default. '
    'This is what makes hybrid billing deterministic: '
    'ABA program can be advance_wallet while speech is session_based, '
    'both within the same institute.';

-- Helper function: resolve billing mode for a session
-- Returns the effective billing mode for a given session.
CREATE OR REPLACE FUNCTION resolve_billing_mode(p_session_id UUID)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_session           session_records%ROWTYPE;
    v_program_override  TEXT;
    v_institute_mode    TEXT;
BEGIN
    SELECT * INTO v_session FROM session_records WHERE id = p_session_id;

    -- Tier 1: Program-level override (most specific)
    IF v_session.therapy_program_id IS NOT NULL THEN
        SELECT billing_model_override INTO v_program_override
        FROM therapy_programs
        WHERE id = v_session.therapy_program_id;

        IF v_program_override IS NOT NULL THEN
            RETURN v_program_override;
        END IF;
    END IF;

    -- Tier 2: Institute default (must be exactly one non-hybrid active mode)
    -- For determinism: select the single non-hybrid mode if institute has one,
    -- or the explicitly configured default if hybrid is the only mode.
    SELECT billing_mode INTO v_institute_mode
    FROM institute_billing_models
    WHERE institute_id  = v_session.institute_id
      AND is_active     = TRUE
      AND billing_mode != 'hybrid'
      AND effective_from <= CURRENT_DATE
      AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
    ORDER BY effective_from DESC
    LIMIT 1;

    IF v_institute_mode IS NOT NULL THEN
        RETURN v_institute_mode;
    END IF;

    -- No mode configured — charge creation will be skipped
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION resolve_billing_mode(UUID) IS
    '[FIX-B1] Deterministic billing mode resolution. '
    'Order: therapy_programs.billing_model_override → institute default (non-hybrid). '
    'Returns NULL if no mode configured (charge creation skipped). '
    'Hybrid at institute level is a flag — actual mode is always resolved per program.';


-- =============================================================================
-- [FIX-B2] billing_charges.amount immutability — wallet settlement layer
-- =============================================================================

-- Add settlement columns to billing_charges
ALTER TABLE billing_charges
    ADD COLUMN IF NOT EXISTS wallet_applied_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS outstanding_amount    NUMERIC(10,2)
        GENERATED ALWAYS AS (amount - wallet_applied_amount) STORED;

ALTER TABLE billing_charges
    ADD CONSTRAINT chk_bc_wallet_applied_nonneg
        CHECK (wallet_applied_amount >= 0),
    ADD CONSTRAINT chk_bc_wallet_not_exceeds_amount
        CHECK (wallet_applied_amount <= amount);

COMMENT ON COLUMN billing_charges.wallet_applied_amount IS
    '[FIX-B2] Amount settled by wallet deduction. '
    'Separate from amount (full charge). '
    'amount is always the full charge (resolved_rate). '
    'outstanding_amount = amount - wallet_applied_amount. '
    'This is the amount that flows to an invoice as a receivable.';

COMMENT ON COLUMN billing_charges.outstanding_amount IS
    '[FIX-B2] Generated: amount - wallet_applied_amount. '
    'The amount that will appear on an invoice line item. '
    'If fully wallet-covered: outstanding_amount = 0 (no invoice line needed). '
    'If partially covered: outstanding_amount = remainder.';

-- Drop the incorrect charge mutation from the old trigger and replace it
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
    v_wt_id             UUID;
BEGIN
    IF NOT (OLD.status = 'in_progress' AND NEW.status = 'completed') THEN
        RETURN NEW;
    END IF;

    -- ── 1. Resolve billing mode (program-aware) ────────────────────────────────
    v_billing_mode := resolve_billing_mode(NEW.id);

    IF v_billing_mode IS NULL THEN RETURN NEW; END IF;
    IF v_billing_mode = 'one_time_fee' THEN RETURN NEW; END IF;

    -- ── 2. Resolve rate ────────────────────────────────────────────────────────
    SELECT r.rate_amount, r.rate_source, r.currency
    INTO v_rate, v_rate_source, v_currency
    FROM resolve_session_rate(NEW.id) r;

    -- ── 3. Insurance authorization (FOR UPDATE, concurrency-safe) ─────────────
    SELECT ia.id INTO v_auth_id
    FROM insurance_authorizations ia
    WHERE ia.patient_id         = NEW.patient_id
      AND ia.institute_id       = NEW.institute_id
      AND ia.is_active          = TRUE
      AND ia.sessions_remaining > 0
      AND ia.valid_from        <= NEW.actual_start::DATE
      AND ia.valid_to          >= NEW.actual_start::DATE
      AND (ia.therapy_type_id  = NEW.therapy_type_id OR ia.therapy_type_id IS NULL)
    ORDER BY ia.therapy_type_id NULLS LAST, ia.valid_from DESC
    LIMIT 1
    FOR UPDATE;

    IF v_auth_id IS NOT NULL THEN
        UPDATE insurance_authorizations
        SET sessions_used = sessions_used + 1, updated_at = NOW()
        WHERE id = v_auth_id;
    END IF;

    -- ── 4. Create charge (amount = full rate, immutable) ─────────────────────
    v_charge_id := generate_uuidv7();

    INSERT INTO billing_charges (
        id, institute_id, patient_id,
        source_type, source_id,
        therapy_type_id, resolved_rate, rate_source,
        amount,         -- always full rate — [FIX-B2]
        currency,
        insurance_authorization_id, is_insurance_eligible,
        charge_status, billing_model,
        wallet_applied_amount   -- starts at 0
    ) VALUES (
        v_charge_id,
        NEW.institute_id, NEW.patient_id,
        'session', NEW.id,
        NEW.therapy_type_id, v_rate, v_rate_source,
        v_rate,
        v_currency,
        v_auth_id, (v_auth_id IS NOT NULL),
        'pending', v_billing_mode,
        0
    );

    -- ── 5. Wallet settlement (separate from charge amount) ────────────────────
    IF v_billing_mode = 'advance_wallet' THEN

        SELECT id, balance INTO v_wallet_id, v_wallet_balance
        FROM patient_wallets
        WHERE patient_id   = NEW.patient_id
          AND institute_id = NEW.institute_id
          AND is_active    = TRUE
        FOR UPDATE;

        IF v_wallet_id IS NOT NULL AND v_wallet_balance > 0 THEN
            v_deduct_amount := LEAST(v_wallet_balance, v_rate);
            v_wt_id         := generate_uuidv7();

            INSERT INTO wallet_transactions (
                id, wallet_id, institute_id,
                transaction_type, amount, balance_after,
                reference_id, reference_type, notes
            ) VALUES (
                v_wt_id, v_wallet_id, NEW.institute_id,
                'debit', v_deduct_amount, v_wallet_balance - v_deduct_amount,
                v_charge_id, 'billing_charge',
                CASE WHEN v_deduct_amount < v_rate
                     THEN 'Partial wallet settlement — outstanding: ' || v_currency || ' ' ||
                          (v_rate - v_deduct_amount)::TEXT
                     ELSE 'Full wallet settlement'
                END
            );

            UPDATE patient_wallets
            SET balance       = balance - v_deduct_amount,
                total_debited = total_debited + v_deduct_amount,
                updated_at    = NOW()
            WHERE id = v_wallet_id;

            -- [FIX-B2] Update ONLY wallet_applied_amount — amount remains immutable
            UPDATE billing_charges
            SET wallet_transaction_id  = v_wt_id,
                wallet_applied_amount  = v_deduct_amount
            WHERE id = v_charge_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION create_charge_on_session_completion() IS
    '[FIX-B1] Uses resolve_billing_mode() — program-aware, deterministic. '
    '[FIX-B2] amount always = resolved_rate (never mutated). '
    '         wallet_applied_amount updated separately (settlement layer). '
    '         outstanding_amount generated: amount - wallet_applied_amount.';

-- Update immutability trigger to also protect wallet_applied_amount post-invoicing
CREATE OR REPLACE FUNCTION enforce_charge_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.charge_status IN ('invoiced','paid','voided','written_off') THEN
        IF NEW.resolved_rate         IS DISTINCT FROM OLD.resolved_rate        OR
           NEW.rate_source           IS DISTINCT FROM OLD.rate_source          OR
           NEW.amount                IS DISTINCT FROM OLD.amount               OR
           NEW.wallet_applied_amount IS DISTINCT FROM OLD.wallet_applied_amount OR
           NEW.patient_id            IS DISTINCT FROM OLD.patient_id           OR
           NEW.source_id             IS DISTINCT FROM OLD.source_id            OR
           NEW.source_type           IS DISTINCT FROM OLD.source_type
        THEN
            RAISE EXCEPTION
                'billing_charge % (status=%) is frozen. '
                'resolved_rate, amount, wallet_applied_amount, and identity fields '
                'cannot change after invoicing. '
                'Create a manual_credit charge for corrections.',
                OLD.id, OLD.charge_status;
        END IF;
    END IF;

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


-- =============================================================================
-- [FIX-B3] Invoice auto-recalculation triggers
-- =============================================================================

-- A: total_amount recalculation when line items are added
CREATE OR REPLACE FUNCTION recalculate_invoice_total()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_invoice_id    UUID;
    v_new_total     NUMERIC(10,2);
    v_inv_status    TEXT;
BEGIN
    v_invoice_id := COALESCE(NEW.invoice_id, OLD.invoice_id);

    SELECT invoice_status INTO v_inv_status FROM invoices WHERE id = v_invoice_id;

    -- Cannot recalculate issued/paid invoices (content frozen)
    IF v_inv_status IN ('issued','paid','partially_paid') THEN
        RAISE EXCEPTION
            'invoice % is % — cannot add or remove line items after issuance.',
            v_invoice_id, v_inv_status;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_new_total
    FROM invoice_line_items
    WHERE invoice_id = v_invoice_id;

    UPDATE invoices
    SET total_amount = v_new_total,
        updated_at   = NOW()
    WHERE id = v_invoice_id;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_invoice_total_recalc
    AFTER INSERT OR DELETE ON invoice_line_items
    FOR EACH ROW EXECUTE FUNCTION recalculate_invoice_total();

COMMENT ON TRIGGER trg_invoice_total_recalc ON invoice_line_items IS
    '[FIX-B3] Recalculates invoice.total_amount on every line item insert/delete. '
    'Blocks modification when invoice is issued/paid. '
    'Fires AFTER INSERT to include the new row in the SUM.';

-- B: paid_amount recalculation + invoice status when payments allocated
CREATE OR REPLACE FUNCTION recalculate_invoice_paid()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_invoice_id        UUID;
    v_total             NUMERIC(10,2);
    v_paid              NUMERIC(10,2);
    v_new_status        TEXT;
    v_current_status    TEXT;
BEGIN
    v_invoice_id := COALESCE(NEW.invoice_id, OLD.invoice_id);

    SELECT total_amount, invoice_status
    INTO v_total, v_current_status
    FROM invoices
    WHERE id = v_invoice_id;

    -- Only update issued/partially_paid invoices
    IF v_current_status NOT IN ('issued','partially_paid') THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    SELECT COALESCE(SUM(allocated_amount), 0) INTO v_paid
    FROM payment_allocations
    WHERE invoice_id = v_invoice_id;

    -- Determine new status
    IF v_paid <= 0 THEN
        v_new_status := 'issued';
    ELSIF v_paid >= v_total THEN
        v_new_status := 'paid';
    ELSE
        v_new_status := 'partially_paid';
    END IF;

    UPDATE invoices
    SET paid_amount    = v_paid,
        invoice_status = v_new_status,
        paid_at        = CASE WHEN v_new_status = 'paid' THEN NOW() ELSE NULL END,
        updated_at     = NOW()
    WHERE id = v_invoice_id;

    -- Update charge status for fully-paid invoices
    IF v_new_status = 'paid' THEN
        UPDATE billing_charges bc
        SET charge_status = 'paid'
        FROM invoice_line_items ili
        WHERE ili.invoice_id  = v_invoice_id
          AND ili.charge_id   = bc.id
          AND bc.charge_status = 'invoiced';
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_invoice_paid_recalc
    AFTER INSERT ON payment_allocations
    FOR EACH ROW EXECUTE FUNCTION recalculate_invoice_paid();

COMMENT ON TRIGGER trg_invoice_paid_recalc ON payment_allocations IS
    '[FIX-B3] Recalculates invoice.paid_amount and advances invoice_status '
    '(issued → partially_paid → paid) on every payment allocation. '
    'Also advances charge_status → paid when invoice is fully settled. '
    'Charges on fully-paid invoices are the only charges that auto-advance.';


-- =============================================================================
-- [FIX-B4] Insurance authorization non-overlap constraint
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_insurance_auth_no_overlap()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_conflict_id UUID;
BEGIN
    -- Only check active authorizations
    IF NOT NEW.is_active THEN RETURN NEW; END IF;

    SELECT id INTO v_conflict_id
    FROM insurance_authorizations
    WHERE patient_id    = NEW.patient_id
      AND institute_id  = NEW.institute_id
      AND is_active     = TRUE
      AND id           != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID)
      AND (therapy_type_id = NEW.therapy_type_id
           OR therapy_type_id IS NULL
           OR NEW.therapy_type_id IS NULL)
      AND daterange(valid_from, valid_to, '[]') && daterange(NEW.valid_from, NEW.valid_to, '[]')
    LIMIT 1;

    IF v_conflict_id IS NOT NULL THEN
        RAISE EXCEPTION
            '[FIX-B4] insurance_authorization conflict: patient % already has an active '
            'authorization (%) that overlaps with the proposed validity window (% to %). '
            'Deactivate the existing authorization before creating a new one, '
            'or ensure the validity windows do not overlap.',
            NEW.patient_id, v_conflict_id, NEW.valid_from, NEW.valid_to;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_insurance_auth_no_overlap
    BEFORE INSERT OR UPDATE OF valid_from, valid_to, is_active, patient_id, therapy_type_id
    ON insurance_authorizations
    FOR EACH ROW EXECUTE FUNCTION enforce_insurance_auth_no_overlap();

COMMENT ON TRIGGER trg_insurance_auth_no_overlap ON insurance_authorizations IS
    '[FIX-B4] Prevents overlapping active authorizations for the same patient + type. '
    'Uses daterange overlap (&&) operator for correct boundary handling. '
    'Charge creation trigger will now always resolve to exactly one authorization. '
    'To renew: set is_active=FALSE on current auth, then create new one.';


-- =============================================================================
-- PATCH B01 SUMMARY
-- =============================================================================
--
--  Fix      | What Changed
-- ──────────┼─────────────────────────────────────────────────────────────────
--  FIX-B1   | therapy_programs.billing_model_override column ADDED
--            | resolve_billing_mode(UUID) function ADDED
--            | create_charge_on_session_completion() REPLACED
--            | Billing mode now: program override → institute default (non-hybrid)
--
--  FIX-B2   | billing_charges.wallet_applied_amount column ADDED
--            | billing_charges.outstanding_amount GENERATED column ADDED
--            | billing_charges.amount NO LONGER MUTATED after wallet deduction
--            | Trigger writes wallet_applied_amount only
--            | enforce_charge_immutability() UPDATED (covers wallet_applied_amount)
--
--  FIX-B3   | trg_invoice_total_recalc ADDED (on invoice_line_items)
--            | trg_invoice_paid_recalc  ADDED (on payment_allocations)
--            | Invoice totals and paid amounts auto-recalculate atomically
--            | invoice_status advances automatically: issued → partially_paid → paid
--            | charge_status advances to 'paid' when invoice fully settled
--
--  FIX-B4   | trg_insurance_auth_no_overlap ADDED
--            | Overlapping active authorizations for same patient+type blocked
--            | charge creation trigger now resolves deterministically
--
-- =============================================================================
-- BILLING FINANCIAL EVENT LAYERING (FINAL)
-- =============================================================================
--
--   Clinical event (session completed)
--           ↓
--   billing_charges.amount = resolved_rate    [IMMUTABLE, full charge]
--   billing_charges.wallet_applied_amount     [settlement layer, set once]
--   billing_charges.outstanding_amount        [generated: amount - wallet_applied]
--           ↓
--   invoice_line_items.amount = outstanding_amount  [receivable]
--   → invoice.total_amount recalculated (trigger)
--           ↓
--   payment_allocations
--   → invoice.paid_amount recalculated (trigger)
--   → invoice_status advanced (trigger)
--   → charge_status → 'paid' when invoice fully settled (trigger)
--
-- =============================================================================
-- PHASE 4 BILLING — PRODUCTION FROZEN
-- =============================================================================