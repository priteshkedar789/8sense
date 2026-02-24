-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 5 — REPORTING MATERIALIZED VIEWS
-- =============================================================================
-- Apply after: all Phase 1–5 files
-- No schema changes to existing tables.
-- =============================================================================
--
-- LOCKED DECISIONS
-- ─────────────────────────────────────────────────────────────────────────────
-- [D-R1] REFRESH MATERIALIZED VIEW CONCURRENTLY on all views.
--        Requires unique index on each view.
--        Reads continue during refresh — no blocking for finance/management users.
--
-- [D-R2] Composite natural keys (Option A).
--        Keys derived from dimension columns (institute_id, date/period, entity).
--        Human-readable, cross-referenceable between views, audit-defensible.
--        No synthetic UUIDs (would change on every refresh, breaking cross-joins).
--
-- [D-R3] Refresh strategy: background hourly (pg_cron or equivalent) +
--        on-demand application trigger.
--        Views may be stale between refreshes — acceptable for management reporting.
--        Finance operations (AR aging) should trigger explicit refresh before export.
--
-- VIEW ORDER (priority-driven):
--   1. mv_ar_aging           — outstanding invoices by age bucket (finance operations)
--   2. mv_wallet_liability   — prepaid wallet balances outstanding (cash flow)
--   3. mv_insurance_auth_depletion — sessions_remaining + expiry proximity (ops)
--   4. mv_provider_utilisation    — scheduled vs delivered by week (management)
--   5. mv_attendance_variance     — scheduled vs attended by program (clinical)
-- =============================================================================


-- =============================================================================
-- VIEW 1 — AR AGING (outstanding invoices by age bucket)
-- =============================================================================
-- Dimensions: institute_id × patient_id × age_bucket
-- Age buckets: current (0–30), overdue_30 (31–60), overdue_60 (61–90), overdue_90 (90+)
-- Source: invoices where invoice_status IN ('issued','partially_paid')
-- Metric: outstanding_amount (total_amount - paid_amount)
-- =============================================================================

CREATE MATERIALIZED VIEW mv_ar_aging AS
SELECT
    i.institute_id,
    i.patient_id,

    -- Age bucket based on days since issuance
    CASE
        WHEN NOW() - i.issued_at <= INTERVAL '30 days'  THEN 'current_0_30'
        WHEN NOW() - i.issued_at <= INTERVAL '60 days'  THEN 'overdue_31_60'
        WHEN NOW() - i.issued_at <= INTERVAL '90 days'  THEN 'overdue_61_90'
        ELSE                                                  'overdue_90_plus'
    END                                     AS age_bucket,

    COUNT(i.id)                             AS invoice_count,
    SUM(i.outstanding_amount)               AS total_outstanding,
    MIN(i.issued_at)::DATE                  AS oldest_invoice_date,
    MAX(i.issued_at)::DATE                  AS newest_invoice_date,
    SUM(i.total_amount)                     AS total_billed,
    SUM(i.paid_amount)                      AS total_collected,
    ROUND(
        100.0 * SUM(i.paid_amount) / NULLIF(SUM(i.total_amount), 0), 1
    )                                       AS collection_rate_pct,
    NOW()                                   AS computed_at

FROM invoices i
WHERE i.invoice_status IN ('issued','partially_paid')
  AND i.issued_at IS NOT NULL
GROUP BY i.institute_id, i.patient_id, age_bucket;

-- Unique index required for CONCURRENTLY refresh
CREATE UNIQUE INDEX uq_mv_ar_aging
    ON mv_ar_aging(institute_id, patient_id, age_bucket);

-- Supporting indexes for query patterns
CREATE INDEX idx_mv_ar_aging_institute  ON mv_ar_aging(institute_id, age_bucket);
CREATE INDEX idx_mv_ar_aging_outstanding ON mv_ar_aging(institute_id, total_outstanding DESC)
    WHERE total_outstanding > 0;

COMMENT ON MATERIALIZED VIEW mv_ar_aging IS
    'Accounts receivable aging by patient and age bucket. '
    'age_bucket: current_0_30, overdue_31_60, overdue_61_90, overdue_90_plus. '
    'Source: invoices with status issued or partially_paid. '
    'Refresh: REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ar_aging; '
    'Stale tolerance: up to 1 hour for routine reporting. '
    'Finance exports: trigger explicit refresh before generating AR report.';


-- =============================================================================
-- VIEW 2 — WALLET LIABILITY (prepaid balances outstanding)
-- =============================================================================
-- Dimensions: institute_id × patient_id
-- Metric: wallet balance (cash the clinic holds that belongs to patients)
-- This is a liability on the clinic's books — must be tracked for cash flow.
-- =============================================================================

CREATE MATERIALIZED VIEW mv_wallet_liability AS
SELECT
    pw.institute_id,
    pw.patient_id,
    pw.currency,
    pw.balance                              AS current_balance,
    pw.credit_balance                       AS total_received,
    pw.total_debited                        AS total_consumed,
    pw.credit_balance - pw.total_debited    AS net_liability,

    -- Sessions the current balance represents at average rate
    -- (informational — requires pricing context to be precise)
    CASE
        WHEN pw.balance <= 0                THEN 'zero_balance'
        WHEN pw.balance < 5000             THEN 'low_lt_5000'
        WHEN pw.balance < 20000            THEN 'medium_5000_20000'
        ELSE                                    'high_gt_20000'
    END                                     AS balance_tier,

    pw.updated_at                           AS last_movement_at,
    NOW()                                   AS computed_at

FROM patient_wallets pw
WHERE pw.is_active = TRUE
  AND pw.balance  > 0;

CREATE UNIQUE INDEX uq_mv_wallet_liability
    ON mv_wallet_liability(institute_id, patient_id);

CREATE INDEX idx_mv_wallet_inst    ON mv_wallet_liability(institute_id, current_balance DESC);
CREATE INDEX idx_mv_wallet_tier    ON mv_wallet_liability(institute_id, balance_tier);

COMMENT ON MATERIALIZED VIEW mv_wallet_liability IS
    'Prepaid wallet balances — clinic liability to patients. '
    'Only includes active wallets with positive balance. '
    'net_liability = total credit received - total deducted '
    '  (should equal current_balance; divergence indicates data issue). '
    'balance_tier: operational segmentation for finance review. '
    'Refresh before cash flow reporting or patient refund processing.';


-- =============================================================================
-- VIEW 3 — INSURANCE AUTH DEPLETION (sessions remaining + expiry)
-- =============================================================================
-- Dimensions: institute_id × patient_id × insurance_authorization_id
-- Priority signals: sessions_remaining = 0, expiry within 30 days
-- Used by: front desk (warn before session), billing (renewal reminders)
-- =============================================================================

CREATE MATERIALIZED VIEW mv_insurance_auth_depletion AS
SELECT
    ia.institute_id,
    ia.patient_id,
    ia.id                                       AS authorization_id,
    ia.insurer_name,
    ia.auth_code,
    ia.therapy_type_id,
    ia.sessions_approved,
    ia.sessions_used,
    ia.sessions_remaining,
    ia.valid_from,
    ia.valid_to,

    -- Days until expiry (negative = already expired)
    (ia.valid_to - CURRENT_DATE)               AS days_until_expiry,

    -- Utilisation percentage
    ROUND(100.0 * ia.sessions_used / NULLIF(ia.sessions_approved, 0), 1)
                                                AS utilisation_pct,

    -- Alert tier for operational dashboards
    CASE
        WHEN ia.valid_to < CURRENT_DATE                             THEN 'expired'
        WHEN ia.sessions_remaining = 0                              THEN 'exhausted'
        WHEN ia.valid_to - CURRENT_DATE <= 14
            OR ia.sessions_remaining <= 3                          THEN 'critical'
        WHEN ia.valid_to - CURRENT_DATE <= 30
            OR ia.sessions_remaining <= 10                         THEN 'warning'
        ELSE                                                             'healthy'
    END                                         AS alert_tier,

    NOW()                                       AS computed_at

FROM insurance_authorizations ia
WHERE ia.is_active = TRUE;

CREATE UNIQUE INDEX uq_mv_auth_depletion
    ON mv_insurance_auth_depletion(institute_id, patient_id, authorization_id);

CREATE INDEX idx_mv_auth_alert    ON mv_insurance_auth_depletion(institute_id, alert_tier)
    WHERE alert_tier IN ('expired','exhausted','critical','warning');
CREATE INDEX idx_mv_auth_expiry   ON mv_insurance_auth_depletion(institute_id, valid_to)
    WHERE alert_tier != 'healthy';

COMMENT ON MATERIALIZED VIEW mv_insurance_auth_depletion IS
    'Insurance authorization status and depletion tracking. '
    'alert_tier: expired, exhausted, critical (≤14 days or ≤3 sessions), '
    '  warning (≤30 days or ≤10 sessions), healthy. '
    'Front desk use: check before session booking. '
    'Billing use: trigger renewal outreach at warning tier. '
    'Refresh hourly. Critical/exhausted tiers may justify on-demand refresh.';


-- =============================================================================
-- VIEW 4 — PROVIDER UTILISATION (blocks scheduled vs sessions delivered)
-- =============================================================================
-- Dimensions: institute_id × provider_id × therapy_type_id × block_type × week
-- Metric: blocks planned, sessions delivered, no-shows, minutes delivered
-- =============================================================================

CREATE MATERIALIZED VIEW mv_provider_utilisation AS
SELECT
    sb.institute_id,
    sb.primary_provider_id                          AS provider_id,
    sb.therapy_type_id,
    sb.block_type,
    DATE_TRUNC('week', sb.scheduled_start)::DATE    AS week_start,

    COUNT(DISTINCT sb.id)                           AS blocks_scheduled,
    COUNT(DISTINCT sb.id)
        FILTER (WHERE sb.block_status = 'completed') AS blocks_completed,
    COUNT(DISTINCT sb.id)
        FILTER (WHERE sb.block_status = 'cancelled') AS blocks_cancelled,

    -- Patient-level outcomes
    COUNT(sbp.id)                                   AS participant_slots,
    COUNT(sbp.id)
        FILTER (WHERE sbp.attendance_status = 'attended')  AS attended,
    COUNT(sbp.id)
        FILTER (WHERE sbp.attendance_status = 'no_show')   AS no_shows,
    COUNT(sbp.id)
        FILTER (WHERE sbp.attendance_status = 'cancelled') AS cancelled_participants,

    -- Session delivery
    COUNT(sbp.session_id)                           AS sessions_generated,

    -- Time metrics (scheduled)
    SUM(
        EXTRACT(EPOCH FROM (sb.scheduled_end - sb.scheduled_start)) / 60
    ) FILTER (WHERE sb.block_status = 'completed')  AS scheduled_minutes_delivered,

    -- Utilisation rate
    ROUND(
        100.0 *
        COUNT(DISTINCT sb.id) FILTER (WHERE sb.block_status = 'completed') /
        NULLIF(COUNT(DISTINCT sb.id) FILTER (WHERE sb.block_status != 'cancelled'), 0),
        1
    )                                               AS block_completion_rate_pct,

    ROUND(
        100.0 *
        COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'attended') /
        NULLIF(COUNT(sbp.id) FILTER (WHERE sbp.attendance_status IN ('attended','no_show')), 0),
        1
    )                                               AS patient_attendance_rate_pct,

    NOW()                                           AS computed_at

FROM schedule_blocks sb
LEFT JOIN schedule_block_participants sbp ON sbp.schedule_block_id = sb.id
GROUP BY
    sb.institute_id,
    sb.primary_provider_id,
    sb.therapy_type_id,
    sb.block_type,
    DATE_TRUNC('week', sb.scheduled_start)::DATE;

CREATE UNIQUE INDEX uq_mv_provider_util
    ON mv_provider_utilisation(institute_id, provider_id, therapy_type_id, block_type, week_start);

CREATE INDEX idx_mv_util_provider  ON mv_provider_utilisation(institute_id, provider_id, week_start DESC);
CREATE INDEX idx_mv_util_week      ON mv_provider_utilisation(institute_id, week_start DESC);

COMMENT ON MATERIALIZED VIEW mv_provider_utilisation IS
    'Provider delivery metrics by week, therapy type, and block type. '
    'block_completion_rate_pct: completed / (scheduled non-cancelled). '
    'patient_attendance_rate_pct: attended / (attended + no_show). '
    'Refresh weekly for management reporting. '
    'Use week_start for trend analysis and therapist performance reviews.';


-- =============================================================================
-- VIEW 5 — ATTENDANCE VARIANCE (scheduled vs attended by program)
-- =============================================================================
-- Dimensions: institute_id × patient_id × therapy_program_id × block_type × month
-- Metric: scheduled slots, attended, no_shows, cancellations, attendance rate
-- Used by: clinical team (program progress), admin (frequency compliance)
-- =============================================================================

CREATE MATERIALIZED VIEW mv_attendance_variance AS
SELECT
    sbp.institute_id,
    sbp.patient_id,
    sbp.therapy_program_id,
    sb.block_type,
    DATE_TRUNC('month', sb.scheduled_start)::DATE   AS month_start,

    COUNT(sbp.id)                                   AS total_slots,
    COUNT(sbp.id)
        FILTER (WHERE sbp.attendance_status = 'attended')           AS attended,
    COUNT(sbp.id)
        FILTER (WHERE sbp.attendance_status = 'partial')            AS partial_attended,
    COUNT(sbp.id)
        FILTER (WHERE sbp.attendance_status = 'no_show')            AS no_shows,
    COUNT(sbp.id)
        FILTER (WHERE sbp.attendance_status = 'cancelled')          AS cancelled,
    COUNT(sbp.id)
        FILTER (WHERE sbp.attendance_status = 'scheduled')          AS still_scheduled,

    -- Attendance rate: attended / (attended + no_show + cancelled)
    ROUND(
        100.0 *
        COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'attended') /
        NULLIF(
            COUNT(sbp.id) FILTER (
                WHERE sbp.attendance_status IN ('attended','partial','no_show','cancelled')
            ), 0
        ),
        1
    )                                               AS attendance_rate_pct,

    -- Cancellation rate: who initiated
    ROUND(
        100.0 *
        COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'cancelled') /
        NULLIF(COUNT(sbp.id), 0),
        1
    )                                               AS cancellation_rate_pct,

    -- Programme frequency: sessions attended vs expected
    -- (expected requires therapy_programs.intended_frequency_per_week * weeks in month)
    COUNT(DISTINCT DATE_TRUNC('week', sb.scheduled_start))
                                                    AS weeks_with_attendance,

    NOW()                                           AS computed_at

FROM schedule_block_participants sbp
JOIN schedule_blocks sb ON sb.id = sbp.schedule_block_id
WHERE sb.block_status != 'cancelled'  -- exclude cancelled blocks from scheduling intent
GROUP BY
    sbp.institute_id,
    sbp.patient_id,
    sbp.therapy_program_id,
    sb.block_type,
    DATE_TRUNC('month', sb.scheduled_start)::DATE;

CREATE UNIQUE INDEX uq_mv_attendance
    ON mv_attendance_variance(institute_id, patient_id, therapy_program_id, block_type, month_start);

CREATE INDEX idx_mv_att_patient   ON mv_attendance_variance(institute_id, patient_id, month_start DESC);
CREATE INDEX idx_mv_att_program   ON mv_attendance_variance(institute_id, therapy_program_id, month_start DESC);
CREATE INDEX idx_mv_att_rate      ON mv_attendance_variance(institute_id, attendance_rate_pct)
    WHERE attendance_rate_pct < 70;  -- flag low-attendance patients for clinical review

COMMENT ON MATERIALIZED VIEW mv_attendance_variance IS
    'Patient attendance by month, program, and block type. '
    'attendance_rate_pct: attended / (attended + partial + no_show + cancelled). '
    'Partial attendance (joined/left early) counted in numerator. '
    'idx_mv_att_rate partial index: < 70% threshold for clinical review flagging. '
    'still_scheduled: future appointments in same month (not yet resolved). '
    'Refresh monthly for clinical team reporting. '
    'Weekly refresh if monitoring active programs.';


-- =============================================================================
-- REFRESH MANAGEMENT
-- =============================================================================

-- Helper function: refresh all reporting views in dependency order
CREATE OR REPLACE FUNCTION refresh_reporting_views()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_catalog AS $$
BEGIN
    -- Financial views first (most time-sensitive)
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ar_aging;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_wallet_liability;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_insurance_auth_depletion;

    -- Management and clinical views
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_provider_utilisation;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_attendance_variance;

    RAISE NOTICE 'All reporting views refreshed at %', NOW();
END;
$$;

COMMENT ON FUNCTION refresh_reporting_views() IS
    'Refreshes all five reporting materialized views concurrently. '
    'Order: financial (AR, wallet, insurance) → operational (utilisation, attendance). '
    'CONCURRENTLY: reads are not blocked during refresh. '
    'Call from: pg_cron (hourly), application on-demand refresh, '
    '  or before generating finance exports. '
    'SECURITY DEFINER + search_path locked (consistent with audit layer).';

-- View to inspect view freshness
CREATE VIEW v_reporting_view_freshness AS
SELECT
    schemaname,
    matviewname                             AS view_name,
    ispopulated                             AS is_populated,
    pg_size_pretty(pg_relation_size(
        (schemaname || '.' || matviewname)::regclass
    ))                                      AS view_size
FROM pg_matviews
WHERE matviewname IN (
    'mv_ar_aging',
    'mv_wallet_liability',
    'mv_insurance_auth_depletion',
    'mv_provider_utilisation',
    'mv_attendance_variance'
)
ORDER BY matviewname;

COMMENT ON VIEW v_reporting_view_freshness IS
    'Operational view for checking materialized view status and size. '
    'ispopulated: FALSE means view needs initial REFRESH before CONCURRENTLY can be used. '
    'Note: PostgreSQL does not store last_refresh_at natively. '
    'Track refresh timestamps in an application-level job log if needed.';


-- =============================================================================
-- PERMISSIONS
-- =============================================================================

INSERT INTO permissions (code, name, module, description) VALUES
    ('CAN_VIEW_REPORTS',    'View Reports',     'reporting',
        'Read access to all reporting materialized views'),
    ('CAN_REFRESH_REPORTS', 'Refresh Reports',  'reporting',
        'Trigger on-demand refresh of reporting views')
ON CONFLICT (code) DO NOTHING;

-- RLS on materialized views
-- Note: PostgreSQL does not support RLS directly on materialized views.
-- Access is controlled via permission (CAN_VIEW_REPORTS) at application layer,
-- and optionally via wrapper functions that filter by institute_id.

-- Institute-scoped wrapper for AR aging (representative pattern)
CREATE OR REPLACE FUNCTION get_ar_aging(p_institute_id UUID DEFAULT NULL)
RETURNS TABLE (
    patient_id      UUID,
    age_bucket      TEXT,
    invoice_count   BIGINT,
    total_outstanding NUMERIC,
    oldest_invoice_date DATE,
    collection_rate_pct NUMERIC,
    computed_at     TIMESTAMPTZ
) LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = public, pg_catalog AS $$
    SELECT
        patient_id, age_bucket, invoice_count,
        total_outstanding, oldest_invoice_date,
        collection_rate_pct, computed_at
    FROM mv_ar_aging
    WHERE institute_id = COALESCE(p_institute_id, current_setting('app.institute_id', TRUE)::UUID)
    ORDER BY total_outstanding DESC, age_bucket;
$$;

COMMENT ON FUNCTION get_ar_aging(UUID) IS
    'Institute-scoped AR aging accessor. '
    'Filters by p_institute_id or app.institute_id session variable. '
    'Use this function in application queries — do not expose raw MV directly. '
    'Pattern applies to all five reporting views.';


-- =============================================================================
-- PHASE 5 REPORTING — INVENTORY
-- =============================================================================
--
-- Materialized views (5):
--   mv_ar_aging                  — outstanding invoices by age bucket
--   mv_wallet_liability          — prepaid wallet balances (clinic liability)
--   mv_insurance_auth_depletion  — sessions remaining + expiry alert tier
--   mv_provider_utilisation      — blocks vs sessions by week
--   mv_attendance_variance       — scheduled vs attended by program + month
--
-- Unique indexes (5, required for CONCURRENTLY refresh):
--   uq_mv_ar_aging               (institute_id, patient_id, age_bucket)
--   uq_mv_wallet_liability       (institute_id, patient_id)
--   uq_mv_auth_depletion         (institute_id, patient_id, authorization_id)
--   uq_mv_provider_util          (institute_id, provider_id, therapy_type_id, block_type, week_start)
--   uq_mv_attendance             (institute_id, patient_id, therapy_program_id, block_type, month_start)
--
-- Supporting indexes (10): query-pattern optimised, partial where appropriate
--
-- Functions:
--   refresh_reporting_views()    — refreshes all 5 views CONCURRENTLY
--   get_ar_aging()               — institute-scoped AR accessor (pattern example)
--
-- Views:
--   v_reporting_view_freshness   — MV status and size
--
-- Note on RLS:
--   PostgreSQL does not support RLS on materialized views.
--   Access controlled via application permission (CAN_VIEW_REPORTS).
--   Wrapper functions (e.g. get_ar_aging) provide institute scoping.
--
-- INITIAL POPULATION (required before CONCURRENTLY can be used):
--   SELECT refresh_reporting_views();
--   -- or individually:
--   REFRESH MATERIALIZED VIEW mv_ar_aging;
--   REFRESH MATERIALIZED VIEW mv_wallet_liability;
--   ... etc
--
-- =============================================================================
-- COMPLETE SYSTEM — ALL PHASES PRODUCTION-FROZEN
-- =============================================================================
--
-- Phase 1:  3 files  — foundation, RBAC, patients
-- Phase 2:  8 files  — form engine, responses, scoring
-- Phase 3:  8 files  — clinical core, sessions, evaluations, events
-- Phase 4:  3 files  — scheduling (block model), billing (multi-model)
-- Phase 5:  6 files  — audit log, room capacity, reporting
-- ─────────────────────────────────────────────────────────────────────────────
-- Total:   28 files  — complete migration sequence
-- =============================================================================
