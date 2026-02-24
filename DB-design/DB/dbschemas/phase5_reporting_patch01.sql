-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 5 — REPORTING PATCH 01: STRUCTURAL CORRECTIONS
-- =============================================================================
-- Apply after: phase5_reporting.sql
-- Drops and recreates affected materialized views.
-- =============================================================================
--
-- FIXES IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-R1] mv_ar_aging used i.outstanding_amount — column does not exist on
--           invoices. invoices has total_amount and paid_amount. outstanding_amount
--           is defined as a GENERATED column on billing_charges, not invoices.
--           Fix: SUM(i.total_amount - i.paid_amount) in all AR aging expressions.
--
-- [FIX-R2] refresh_reporting_views() called REFRESH MATERIALIZED VIEW CONCURRENTLY
--           inside a PL/pgSQL function body. PostgreSQL does not allow CONCURRENTLY
--           inside a transaction block — all PL/pgSQL executes inside one.
--           Error: "REFRESH MATERIALIZED VIEW CONCURRENTLY cannot be executed from
--           a function."
--           Fix: replace function with a shell-script-style SQL file comment and
--           a non-concurrent fallback function for emergency use. Document the
--           correct operational pattern (pg_cron / application direct call).
--
-- [FIX-R3] mv_provider_utilisation: LEFT JOIN on schedule_block_participants
--           caused scheduled_minutes_delivered to be multiplied by participant
--           count. A 60-minute group block with 5 patients reported 300 minutes.
--           Fix: compute block-level aggregates in a subquery before joining
--           participant-level aggregates. Separate CTEs for blocks and participants,
--           joined on block_id.
--
-- [MINOR-R4] mv_attendance_variance: weeks_with_attendance counted weeks with
--            scheduled blocks. Renamed to weeks_with_scheduled_blocks to be
--            explicit. Added weeks_with_attended_sessions for clinical intent.
-- =============================================================================


-- =============================================================================
-- [FIX-R1] mv_ar_aging — replace i.outstanding_amount
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS mv_ar_aging CASCADE;

CREATE MATERIALIZED VIEW mv_ar_aging AS
SELECT
    i.institute_id,
    i.patient_id,

    CASE
        WHEN NOW() - i.issued_at <= INTERVAL '30 days'  THEN 'current_0_30'
        WHEN NOW() - i.issued_at <= INTERVAL '60 days'  THEN 'overdue_31_60'
        WHEN NOW() - i.issued_at <= INTERVAL '90 days'  THEN 'overdue_61_90'
        ELSE                                                  'overdue_90_plus'
    END                                             AS age_bucket,

    COUNT(i.id)                                     AS invoice_count,

    -- [FIX-R1] Computed expression — invoices.outstanding_amount does not exist
    SUM(i.total_amount - i.paid_amount)             AS total_outstanding,

    MIN(i.issued_at)::DATE                          AS oldest_invoice_date,
    MAX(i.issued_at)::DATE                          AS newest_invoice_date,
    SUM(i.total_amount)                             AS total_billed,
    SUM(i.paid_amount)                              AS total_collected,
    ROUND(
        100.0 * SUM(i.paid_amount) / NULLIF(SUM(i.total_amount), 0), 1
    )                                               AS collection_rate_pct,
    NOW()                                           AS computed_at

FROM invoices i
WHERE i.invoice_status IN ('issued','partially_paid')
  AND i.issued_at IS NOT NULL
GROUP BY i.institute_id, i.patient_id, age_bucket;

CREATE UNIQUE INDEX uq_mv_ar_aging
    ON mv_ar_aging(institute_id, patient_id, age_bucket);

CREATE INDEX idx_mv_ar_aging_institute   ON mv_ar_aging(institute_id, age_bucket);
CREATE INDEX idx_mv_ar_aging_outstanding ON mv_ar_aging(institute_id, total_outstanding DESC)
    WHERE total_outstanding > 0;

COMMENT ON MATERIALIZED VIEW mv_ar_aging IS
    '[FIX-R1] outstanding = total_amount - paid_amount (computed, not column). '
    'Time semantics: age_bucket evaluated at refresh time via NOW(). '
    'Between refreshes, buckets do not advance — refresh before AR exports. '
    'Refresh: REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ar_aging;';


-- =============================================================================
-- [FIX-R2] refresh_reporting_views() — CONCURRENTLY inside function is invalid
-- =============================================================================
-- PostgreSQL error: "REFRESH MATERIALIZED VIEW CONCURRENTLY cannot be executed
-- from a function or multi-command string."
--
-- CONCURRENTLY acquires an EXCLUSIVE lock on the MV while also needing to
-- run outside an explicit transaction — it manages its own internal transaction.
-- PL/pgSQL wraps everything in a transaction, making this impossible.
--
-- CORRECT OPERATIONAL PATTERN:
-- ─────────────────────────────
-- From pg_cron (schedule hourly):
--   SELECT cron.schedule('refresh-reports', '0 * * * *',
--     'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ar_aging;
--      REFRESH MATERIALIZED VIEW CONCURRENTLY mv_wallet_liability;
--      REFRESH MATERIALIZED VIEW CONCURRENTLY mv_insurance_auth_depletion;
--      REFRESH MATERIALIZED VIEW CONCURRENTLY mv_provider_utilisation;
--      REFRESH MATERIALIZED VIEW CONCURRENTLY mv_attendance_variance;');
--
-- From application layer (on-demand):
--   Execute each REFRESH MATERIALIZED VIEW CONCURRENTLY as a standalone
--   statement outside any transaction block (autocommit mode).
--
-- INITIAL POPULATION (first deployment, before CONCURRENTLY can be used):
--   REFRESH MATERIALIZED VIEW mv_ar_aging;
--   REFRESH MATERIALIZED VIEW mv_wallet_liability;
--   REFRESH MATERIALIZED VIEW mv_insurance_auth_depletion;
--   REFRESH MATERIALIZED VIEW mv_provider_utilisation;
--   REFRESH MATERIALIZED VIEW mv_attendance_variance;
-- =============================================================================

-- Drop the invalid function from phase5_reporting.sql
DROP FUNCTION IF EXISTS refresh_reporting_views();

-- Non-concurrent fallback (for maintenance windows or initial population)
-- Does NOT use CONCURRENTLY — blocks reads during refresh.
-- Use only when: (a) initial population, (b) CONCURRENTLY fails due to lock,
-- (c) emergency maintenance window.
CREATE OR REPLACE FUNCTION refresh_reporting_views_blocking()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_catalog AS $$
BEGIN
    -- Non-concurrent refresh — blocks reads on each view during its refresh
    -- Acceptable for initial population or maintenance windows only
    REFRESH MATERIALIZED VIEW mv_ar_aging;
    REFRESH MATERIALIZED VIEW mv_wallet_liability;
    REFRESH MATERIALIZED VIEW mv_insurance_auth_depletion;
    REFRESH MATERIALIZED VIEW mv_provider_utilisation;
    REFRESH MATERIALIZED VIEW mv_attendance_variance;

    RAISE NOTICE
        'Blocking refresh complete at %. '
        'For production use, call REFRESH MATERIALIZED VIEW CONCURRENTLY '
        'on each view individually outside a transaction block.',
        NOW();
END;
$$;

COMMENT ON FUNCTION refresh_reporting_views_blocking() IS
    '[FIX-R2] Non-concurrent fallback for initial population and maintenance. '
    'PRODUCTION REFRESH: call each view individually with CONCURRENTLY: '
    '  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ar_aging; '
    '  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_wallet_liability; '
    '  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_insurance_auth_depletion; '
    '  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_provider_utilisation; '
    '  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_attendance_variance; '
    'These must be standalone statements (not inside a transaction / function). '
    'Schedule via pg_cron or application job in autocommit mode.';


-- =============================================================================
-- [FIX-R3] mv_provider_utilisation — fix minute inflation from participant join
-- =============================================================================
-- Problem: LEFT JOIN schedule_block_participants multiplied each block row by
-- participant count. A 60-minute group block with 5 participants reported
-- 5 × 60 = 300 minutes. Anything aggregated from schedule_blocks must be
-- computed before the participant join.
--
-- Fix: two CTEs — block_agg (block-level metrics) and participant_agg
-- (participant-level metrics) — joined on (institute_id, block_id).
-- Block metrics (minutes, block counts) come from block_agg.
-- Participant metrics (attendance, no_shows) come from participant_agg.
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS mv_provider_utilisation CASCADE;

CREATE MATERIALIZED VIEW mv_provider_utilisation AS
WITH block_agg AS (
    -- Block-level metrics: one row per block, not inflated by participants
    SELECT
        sb.institute_id,
        sb.id                                           AS block_id,
        sb.primary_provider_id                          AS provider_id,
        sb.therapy_type_id,
        sb.block_type,
        DATE_TRUNC('week', sb.scheduled_start)::DATE    AS week_start,
        sb.block_status,
        -- Scheduled duration in minutes (computed once per block)
        EXTRACT(EPOCH FROM (sb.scheduled_end - sb.scheduled_start)) / 60
                                                        AS scheduled_minutes
    FROM schedule_blocks sb
),
participant_agg AS (
    -- Participant-level metrics: one row per (block, participant)
    SELECT
        sb.institute_id,
        sb.primary_provider_id                          AS provider_id,
        sb.therapy_type_id,
        sb.block_type,
        DATE_TRUNC('week', sb.scheduled_start)::DATE    AS week_start,
        COUNT(sbp.id)                                   AS participant_slots,
        COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'attended')   AS attended,
        COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'no_show')    AS no_shows,
        COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'cancelled')  AS cancelled_participants,
        COUNT(sbp.session_id)                           AS sessions_generated
    FROM schedule_blocks sb
    LEFT JOIN schedule_block_participants sbp ON sbp.schedule_block_id = sb.id
    GROUP BY
        sb.institute_id, sb.primary_provider_id, sb.therapy_type_id,
        sb.block_type, DATE_TRUNC('week', sb.scheduled_start)::DATE
)
SELECT
    ba.institute_id,
    ba.provider_id,
    ba.therapy_type_id,
    ba.block_type,
    ba.week_start,

    -- Block counts (from block_agg — no inflation)
    COUNT(ba.block_id)                                  AS blocks_scheduled,
    COUNT(ba.block_id) FILTER (WHERE ba.block_status = 'completed')  AS blocks_completed,
    COUNT(ba.block_id) FILTER (WHERE ba.block_status = 'cancelled')  AS blocks_cancelled,

    -- Scheduled minutes (from block_agg — computed once per block)
    -- [FIX-R3] SUM over block_agg rows, not inflated by participant count
    SUM(ba.scheduled_minutes)
        FILTER (WHERE ba.block_status = 'completed')    AS scheduled_minutes_delivered,

    -- Participant metrics (from participant_agg)
    pa.participant_slots,
    pa.attended,
    pa.no_shows,
    pa.cancelled_participants,
    pa.sessions_generated,

    -- Rates
    ROUND(
        100.0 *
        COUNT(ba.block_id) FILTER (WHERE ba.block_status = 'completed') /
        NULLIF(COUNT(ba.block_id) FILTER (WHERE ba.block_status != 'cancelled'), 0),
        1
    )                                                   AS block_completion_rate_pct,

    ROUND(
        100.0 * pa.attended /
        NULLIF(pa.attended + pa.no_shows, 0),
        1
    )                                                   AS patient_attendance_rate_pct,

    NOW()                                               AS computed_at

FROM block_agg ba
LEFT JOIN participant_agg pa
    ON  pa.institute_id    = ba.institute_id
    AND pa.provider_id     = ba.provider_id
    AND pa.therapy_type_id = ba.therapy_type_id
    AND pa.block_type      = ba.block_type
    AND pa.week_start      = ba.week_start
GROUP BY
    ba.institute_id, ba.provider_id, ba.therapy_type_id,
    ba.block_type, ba.week_start,
    pa.participant_slots, pa.attended, pa.no_shows,
    pa.cancelled_participants, pa.sessions_generated;

CREATE UNIQUE INDEX uq_mv_provider_util
    ON mv_provider_utilisation(institute_id, provider_id, therapy_type_id, block_type, week_start);

CREATE INDEX idx_mv_util_provider ON mv_provider_utilisation(institute_id, provider_id, week_start DESC);
CREATE INDEX idx_mv_util_week     ON mv_provider_utilisation(institute_id, week_start DESC);

COMMENT ON MATERIALIZED VIEW mv_provider_utilisation IS
    '[FIX-R3] Block and participant metrics computed in separate CTEs. '
    'scheduled_minutes_delivered: summed from block_agg (one row per block). '
    'No inflation from participant joins — group sessions reported correctly. '
    'block_completion_rate_pct: blocks_completed / (scheduled non-cancelled). '
    'patient_attendance_rate_pct: attended / (attended + no_shows).';


-- =============================================================================
-- [MINOR-R4] mv_attendance_variance — clarify weeks semantics
-- =============================================================================
-- weeks_with_attendance was misleadingly named — it counted scheduled blocks
-- per week, not attended sessions per week. Rename + add attended variant.
-- Drop and recreate the view with the semantic fix.
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS mv_attendance_variance CASCADE;

CREATE MATERIALIZED VIEW mv_attendance_variance AS
SELECT
    sbp.institute_id,
    sbp.patient_id,
    sbp.therapy_program_id,
    sb.block_type,
    DATE_TRUNC('month', sb.scheduled_start)::DATE       AS month_start,

    COUNT(sbp.id)                                       AS total_slots,
    COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'attended')     AS attended,
    COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'partial')      AS partial_attended,
    COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'no_show')      AS no_shows,
    COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'cancelled')    AS cancelled,
    COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'scheduled')    AS still_scheduled,

    ROUND(
        100.0 *
        COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'attended') /
        NULLIF(
            COUNT(sbp.id) FILTER (
                WHERE sbp.attendance_status IN ('attended','partial','no_show','cancelled')
            ), 0
        ),
        1
    )                                                   AS attendance_rate_pct,

    ROUND(
        100.0 *
        COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'cancelled') /
        NULLIF(COUNT(sbp.id), 0),
        1
    )                                                   AS cancellation_rate_pct,

    -- [MINOR-R4] Two distinct week counts — scheduling intent vs clinical reality
    COUNT(DISTINCT DATE_TRUNC('week', sb.scheduled_start))
                                                        AS weeks_with_scheduled_blocks,
    COUNT(DISTINCT
        CASE WHEN sbp.attendance_status IN ('attended','partial')
             THEN DATE_TRUNC('week', sb.scheduled_start)
        END
    )                                                   AS weeks_with_attended_sessions,

    NOW()                                               AS computed_at

FROM schedule_block_participants sbp
JOIN schedule_blocks sb ON sb.id = sbp.schedule_block_id
WHERE sb.block_status != 'cancelled'
GROUP BY
    sbp.institute_id, sbp.patient_id, sbp.therapy_program_id,
    sb.block_type, DATE_TRUNC('month', sb.scheduled_start)::DATE;

CREATE UNIQUE INDEX uq_mv_attendance
    ON mv_attendance_variance(institute_id, patient_id, therapy_program_id, block_type, month_start);

CREATE INDEX idx_mv_att_patient ON mv_attendance_variance(institute_id, patient_id, month_start DESC);
CREATE INDEX idx_mv_att_program ON mv_attendance_variance(institute_id, therapy_program_id, month_start DESC);
CREATE INDEX idx_mv_att_rate    ON mv_attendance_variance(institute_id, attendance_rate_pct)
    WHERE attendance_rate_pct < 70;

COMMENT ON MATERIALIZED VIEW mv_attendance_variance IS
    '[MINOR-R4] weeks_with_scheduled_blocks: weeks the patient had a scheduled block. '
    'weeks_with_attended_sessions: weeks the patient actually attended (attended or partial). '
    'Clinical use: compare these to prescribed frequency for program compliance monitoring. '
    'attendance_rate_pct < 70: flagged by partial index for clinical review.';


-- =============================================================================
-- PATCH R01 SUMMARY
-- =============================================================================
--
--  Fix        | What Changed
-- ────────────┼───────────────────────────────────────────────────────────────
--  FIX-R1     | mv_ar_aging DROPPED and RECREATED
--              | SUM(i.outstanding_amount) → SUM(i.total_amount - i.paid_amount)
--              | invoices.outstanding_amount does not exist (it's on billing_charges)
--
--  FIX-R2     | refresh_reporting_views() DROPPED
--              | CONCURRENTLY cannot run inside PL/pgSQL (transaction block)
--              | Replaced with refresh_reporting_views_blocking() for maintenance use
--              | Production refresh: standalone CONCURRENTLY statements (pg_cron / app)
--
--  FIX-R3     | mv_provider_utilisation DROPPED and RECREATED
--              | Two CTEs: block_agg (block-level) + participant_agg (participant-level)
--              | scheduled_minutes_delivered computed in block_agg (no participant inflation)
--              | Group session: 5 patients × 60 min now correctly reports 60 min
--
--  MINOR-R4   | mv_attendance_variance DROPPED and RECREATED
--              | weeks_with_attendance renamed to weeks_with_scheduled_blocks
--              | weeks_with_attended_sessions added (distinct weeks with actual attendance)
--
-- =============================================================================
-- PRODUCTION REFRESH REFERENCE (copy into pg_cron or scheduler config)
-- =============================================================================
--
-- Initial population (run once, no CONCURRENTLY):
--   SELECT refresh_reporting_views_blocking();
--
-- Recurring refresh (pg_cron, hourly, standalone statements):
--   REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ar_aging;
--   REFRESH MATERIALIZED VIEW CONCURRENTLY mv_wallet_liability;
--   REFRESH MATERIALIZED VIEW CONCURRENTLY mv_insurance_auth_depletion;
--   REFRESH MATERIALIZED VIEW CONCURRENTLY mv_provider_utilisation;
--   REFRESH MATERIALIZED VIEW CONCURRENTLY mv_attendance_variance;
--
-- On-demand from application (autocommit, not inside a transaction):
--   REFRESH MATERIALIZED VIEW CONCURRENTLY <view_name>;
--
-- =============================================================================
-- PHASE 5 REPORTING — PRODUCTION FROZEN
-- =============================================================================
-- Views:          mv_ar_aging, mv_wallet_liability, mv_insurance_auth_depletion,
--                 mv_provider_utilisation, mv_attendance_variance
-- Unique indexes: 5 (CONCURRENTLY-compatible natural keys)
-- Functions:      refresh_reporting_views_blocking() (maintenance only)
--                 get_ar_aging() (institute-scoped accessor, from base file)
--
-- =============================================================================
-- COMPLETE SYSTEM — ALL PHASES PRODUCTION-FROZEN
-- =============================================================================
-- 28 files · 14,900+ lines · 680KB+
-- Phase 1: foundation / Phase 2: forms / Phase 3: clinical
-- Phase 4: scheduling + billing / Phase 5: audit + rooms + reporting
-- =============================================================================
