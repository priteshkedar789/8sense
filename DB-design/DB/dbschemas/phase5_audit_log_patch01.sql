-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 5 — AUDIT LOG PATCH 01: SECURITY DEFINER SEARCH_PATH HARDENING
-- =============================================================================
-- Apply after: phase5_audit_log.sql
-- =============================================================================
--
-- FIX: Explicit search_path on all SECURITY DEFINER functions.
--
-- Without SET search_path, SECURITY DEFINER functions resolve object names
-- using the calling session's search_path at execution time. If a malicious
-- schema is injected earlier in search_path (e.g. via CREATE SCHEMA attack),
-- the function could resolve table references to shadow objects.
--
-- Mitigation: SET search_path = public, pg_catalog on each function.
-- This locks resolution to the public schema and system catalog regardless
-- of the calling session's search_path.
--
-- Affected functions (all SECURITY DEFINER):
--   capture_audit_log()
--   audit_history()
--   audit_table_window()
--   audit_by_user()
--   audit_field_transitions()
-- =============================================================================

ALTER FUNCTION capture_audit_log()
    SET search_path = public, pg_catalog;

ALTER FUNCTION audit_history(TEXT, UUID)
    SET search_path = public, pg_catalog;

ALTER FUNCTION audit_table_window(TEXT, TIMESTAMPTZ, TIMESTAMPTZ)
    SET search_path = public, pg_catalog;

ALTER FUNCTION audit_by_user(UUID, TIMESTAMPTZ, TIMESTAMPTZ)
    SET search_path = public, pg_catalog;

ALTER FUNCTION audit_field_transitions(TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ)
    SET search_path = public, pg_catalog;

-- Verify (informational)
SELECT
    p.proname                           AS function_name,
    p.prosecdef                         AS security_definer,
    p.proconfig                         AS config  -- should contain search_path
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
      'capture_audit_log',
      'audit_history',
      'audit_table_window',
      'audit_by_user',
      'audit_field_transitions'
  )
ORDER BY p.proname;

-- =============================================================================
-- PHASE 5 AUDIT LOG — PRODUCTION FROZEN
-- =============================================================================
--
-- All SECURITY DEFINER functions in the audit layer now have:
--   search_path = public, pg_catalog
--
-- This applies the same hardening standard as:
--   resolve_session_rate()     (phase4_billing.sql)
--   resolve_billing_mode()     (phase4_billing_patch01.sql)
--   log_score()                (phase2 scoring governance)
--
-- No schema changes. No logic changes. No cross-dependencies.
--
-- Complete phase5 audit migration:
--   phase5_audit_log.sql          — table, trigger, helpers
--   phase5_audit_log_patch01.sql  — search_path hardening  ← this file
-- =============================================================================
