# Therapy Institute Platform — Migration Runbook

## System Overview

**28 files · 14,822 lines · 681KB**  
Production-frozen: all phases reviewed and structurally hardened.

---

## Migration Sequence

Apply files in this exact order. Each file depends on all preceding ones.

```
 1.  phase1_foundation.sql
 2.  phase1_patch01.sql
 3.  phase1_patch02.sql
 4.  phase2_form_definition.sql
 5.  phase2_form_definition_patch01.sql
 6.  phase2_form_definition_patch02.sql
 7.  phase2_form_definition_patch03.sql
 8.  phase2_form_responses.sql
 9.  phase2_form_responses_patch01.sql
10.  phase2_form_responses_patch02.sql
11.  phase2_form_responses_patch03.sql
12.  phase3_clinical_core_foundation.sql
13.  phase3_clinical_core_foundation_patch01.sql
14.  phase3_session_records.sql
15.  phase3_session_records_patch01.sql
16.  phase3_evaluations.sql
17.  phase3_evaluations_patch01.sql
18.  phase3_clinical_events.sql
19.  phase3_clinical_events_patch01.sql
20.  phase4_scheduling.sql
21.  phase4_billing.sql
22.  phase4_billing_patch01.sql
23.  phase5_audit_log.sql
24.  phase5_audit_log_patch01.sql
25.  phase5_room_capacity.sql
26.  phase5_room_capacity_patch01.sql
27.  phase5_reporting.sql
28.  phase5_reporting_patch01.sql
```

---

## Pre-Migration Checks

### 1. Existing data conflict check (Phase 5 room capacity)
Before applying files 25–26 on any system with existing `schedule_blocks` data:

```sql
SELECT * FROM v_room_scheduling_conflicts WHERE conflict_type != 'OK';
```

If this returns rows, resolve scheduling conflicts before proceeding.  
If it returns nothing, migration is safe.

### 2. Extensions required
```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- Phase 4: provider overlap EXCLUDE
CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- Phase 1: generate_uuidv7() if not built-in
```

---

## Post-Migration Steps

### 1. Initial MV population (required before CONCURRENTLY can be used)
```sql
SELECT refresh_reporting_views_blocking();
```

This populates all five materialized views using blocking refresh.  
Run once after initial deployment. Subsequent refreshes use CONCURRENTLY.

### 2. Verify MV population
```sql
SELECT * FROM v_reporting_view_freshness;
-- ispopulated should be TRUE for all 5 views
```

### 3. Application session variable contract
The application layer must set these at the start of every transaction:
```sql
SET LOCAL app.current_user_id  = '<uuid>';
SET LOCAL app.current_role     = 'clinician';   -- or other role
SET LOCAL app.request_id       = '<uuid>';
SET LOCAL app.client_ip        = '<ip>';
SET LOCAL app.institute_id     = '<uuid>';
```
`SET LOCAL` scopes these to the transaction — reset automatically on commit/rollback.  
Required by: RLS helper functions, audit trigger, reporting wrapper functions.

---

## pg_cron Configuration

```sql
-- Hourly reporting view refresh (standalone CONCURRENTLY calls — not in a function)
SELECT cron.schedule('refresh-mv-ar-aging',
    '0 * * * *',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ar_aging');

SELECT cron.schedule('refresh-mv-wallet',
    '5 * * * *',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_wallet_liability');

SELECT cron.schedule('refresh-mv-insurance',
    '10 * * * *',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_insurance_auth_depletion');

SELECT cron.schedule('refresh-mv-utilisation',
    '15 * * * *',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_provider_utilisation');

SELECT cron.schedule('refresh-mv-attendance',
    '20 * * * *',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_attendance_variance');
```

Note: stagger start times by 5 minutes to avoid concurrent refresh contention.

---

## Key Architectural Invariants

| Invariant | Enforcement |
|---|---|
| One charge per session | `uq_bc_session_charge` UNIQUE constraint |
| Charge amount immutable post-invoice | `trg_charge_immutability` |
| Wallet cannot double-spend | `FOR UPDATE` on `patient_wallets` |
| Rate stamped at creation, never recomputed | `NOT NULL resolved_rate` + immutability trigger |
| Session amendment never touches billing | No FK from billing → clinical |
| Lifecycle transitions forward-only | Per-table lifecycle triggers (BEFORE UPDATE) |
| Audit fires after all enforcement | AFTER UPDATE triggers on 8 tables |
| Room capacity race-safe | `FOR UPDATE` on `rooms` row |
| Institute boundary throughout | Composite FKs on all cross-entity references |
| MV refresh non-blocking | `CONCURRENTLY` (standalone, not in function) |

---

## Phase Inventory

### Phase 1 — Foundation (3 files, 1,853 lines)
Platform hierarchy (platforms → institutes → branches), multi-tenant RBAC,
RLS primitives (`current_institute_id()`, `current_user_has_permission()`),
patient registry with composite FK isolation.

### Phase 2 — Form Engine (8 files, 3,801 lines)
Instrument definition, question versioning, form templates, response lifecycle
(draft → submitted → reviewed → locked), dual-barrier scoring immutability,
system-only scoring guard, PCR gate on active programs.

### Phase 3 — Clinical Core (8 files, 4,435 lines)
Therapy programs + PCR versioning chain, session records (dual-domain freeze:
`status` + `note_status`), evaluations (instrument submission gate, interpretive
scoring), clinical events (milestone hybrid model, case conferences, MDT freeze).

### Phase 4 — Operations (3 files, 2,359 lines)
**Scheduling:** capacity-based block model (individual/group/parallel/co_therapy/
assessment), per-participant promotion to `session_records`, provider + patient
overlap detection (EXCLUDE + trigger), co-provider roster.  
**Billing:** multi-model engine (session_based/advance_wallet/one_time_fee),
program-aware billing mode resolution, stamped-rate immutable charges, wallet
settlement layer (separate from charge amount), invoice auto-recalculation
triggers, insurance authorization tracking.

### Phase 5 — Infrastructure (6 files, 2,374 lines)
**Audit log:** AFTER UPDATE on 8 high-governance tables, SECURITY DEFINER +
`search_path` locked, full JSONB snapshots, trigger-driven mutation capture,
`changed_fields` array for efficient querying.  
**Room capacity:** dual-mode (exclusive/shared), `room_policy` per room,
peak-overlap capacity reduction check, policy downgrade locking, co-provider
UPDATE coverage.  
**Reporting:** 5 materialized views with CONCURRENTLY-compatible unique indexes,
CTE-based fan-out prevention, blocking fallback refresh function.

---

## Optional Next Workstreams (post-freeze)

These are hardening passes, not structural requirements:

1. **Performance audit** — `EXPLAIN ANALYZE` on `enforce_room_capacity()` peak
   overlap self-join and `enforce_patient_block_no_overlap()` under load.
   Confirm index usage with realistic data volumes.

2. **Deadlock simulation** — concurrent room downgrade + block insert, wallet
   deduction + charge status update, insurance auth depletion + charge creation.
   Lock acquisition order is consistent across all paths — simulation confirms
   the analysis holds under actual PostgreSQL behaviour.

3. **Load modeling** — project `schedule_blocks`, `audit_log`, and MV refresh
   costs at target session volume (sessions/day × therapist count × patient
   population). Determines whether monthly MV partitioning is warranted.
