-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 5 — ROOM CAPACITY + MULTI-THERAPIST ENFORCEMENT
-- =============================================================================
-- Apply after: phase4_scheduling.sql, phase5_audit_log.sql
-- No new tables. Extends: rooms, schedule_blocks, schedule_block_providers.
-- =============================================================================
--
-- LOCKED DECISIONS
-- ─────────────────────────────────────────────────────────────────────────────
-- [D-RC1] Dual room policy model.
--         'exclusive' → one block per room per time window.
--         'shared'    → multiple blocks allowed; SUM(block.capacity) ≤ room.capacity.
--         Policy is per-room, not global.
--
-- [D-RC2] Capacity enforcement uses schedule_blocks.capacity (predictive model).
--         Prevents overscheduling. Consistent with existing block capacity semantics.
--         Not participant count (reactive) — enforced at scheduling time.
--
-- [D-RC3] Multi-therapist per block allowed via schedule_block_providers (Phase 4).
--         Co-providers must not overlap with any other block (as primary or co-provider).
--         Primary provider already protected by excl_provider_no_overlap (Phase 4).
--
-- [D-RC4] room_policy immutability rules:
--         Immutable if any block has already started (block_status IN ('in_progress','completed')).
--         Mutable for future bookings (all blocks still scheduled/confirmed/cancelled).
--         Policy downgrade (shared → exclusive) also requires no overlapping future blocks.
--
-- WHY TRIGGERS INSTEAD OF EXCLUSION CONSTRAINTS FOR ROOM ENFORCEMENT
-- ─────────────────────────────────────────────────────────────────────────────
-- PostgreSQL EXCLUDE constraints cannot reference other tables in their WHERE
-- predicate (room_policy lives on rooms, not schedule_blocks). Options:
--   A) Denormalize room_policy onto schedule_blocks → data integrity risk.
--   B) Functional GiST index → does not enforce on INSERT.
--   C) Trigger with FOR UPDATE on rooms row → concurrency-safe, no denorm.
-- Option C is chosen: consistent with shared-room aggregate enforcement,
-- and with the system's trigger-based cross-table invariant pattern.
-- =============================================================================


-- =============================================================================
-- SECTION 1 — ROOMS POLICY MODEL
-- =============================================================================

-- Add room_policy to rooms table
ALTER TABLE rooms
    ADD COLUMN IF NOT EXISTS room_policy TEXT NOT NULL DEFAULT 'exclusive';

ALTER TABLE rooms
    ADD CONSTRAINT chk_room_policy
        CHECK (room_policy IN ('exclusive','shared'));

-- Ensure capacity is strictly positive (rooms.capacity was already stored;
-- adding explicit NOT NULL + positive constraint if not already present)
ALTER TABLE rooms
    ADD CONSTRAINT chk_room_capacity_positive
        CHECK (capacity > 0);

-- Block capacity must not exceed room capacity (cross-table constraint via trigger)
-- Handled in Section 2 triggers.

COMMENT ON COLUMN rooms.room_policy IS
    '[D-RC1] Determines room enforcement model. '
    'exclusive: only one schedule_block at a time. '
    'shared: multiple blocks allowed; SUM(block.capacity) of overlapping blocks ≤ room.capacity. '
    'Policy change rules: immutable once any block has started. '
    'Downgrade (shared → exclusive) requires no overlapping future blocks.';


-- =============================================================================
-- SECTION 2 — ROOM POLICY CHANGE ENFORCEMENT
-- =============================================================================
-- room_policy is immutable if any block for this room has started.
-- Downgrade shared → exclusive requires no overlapping future blocks.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_room_policy_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_conflict_id UUID;
BEGIN
    IF NEW.room_policy = OLD.room_policy THEN RETURN NEW; END IF;

    -- Lock the room row (prevents concurrent policy change + block creation race)
    PERFORM id FROM rooms WHERE id = NEW.id FOR UPDATE;

    -- Immutable if any block has started (in_progress or completed)
    IF EXISTS (
        SELECT 1 FROM schedule_blocks
        WHERE room_id    = NEW.id
          AND block_status IN ('in_progress','completed')
    ) THEN
        RAISE EXCEPTION
            '[D-RC4] room % policy cannot change — blocks in progress or completed exist. '
            'A started session anchors the room context.',
            NEW.id;
    END IF;

    -- Downgrade shared → exclusive: no overlapping future blocks allowed
    IF OLD.room_policy = 'shared' AND NEW.room_policy = 'exclusive' THEN
        SELECT a.id INTO v_conflict_id
        FROM schedule_blocks a
        JOIN schedule_blocks b ON b.id != a.id
        WHERE a.room_id     = NEW.id
          AND b.room_id     = NEW.id
          AND a.block_status NOT IN ('cancelled','completed')
          AND b.block_status NOT IN ('cancelled','completed')
          AND tstzrange(a.scheduled_start, a.scheduled_end, '[)')
              && tstzrange(b.scheduled_start, b.scheduled_end, '[)')
        LIMIT 1;

        IF v_conflict_id IS NOT NULL THEN
            RAISE EXCEPTION
                '[D-RC4] room % cannot switch to exclusive — overlapping future blocks exist (e.g. %). '
                'Resolve scheduling conflicts before converting to exclusive policy.',
                NEW.id, v_conflict_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_room_policy_change
    BEFORE UPDATE OF room_policy ON rooms
    FOR EACH ROW EXECUTE FUNCTION enforce_room_policy_change();

COMMENT ON TRIGGER trg_room_policy_change ON rooms IS
    '[D-RC4] Guards room_policy changes. '
    'Blocks change if any block is in_progress or completed. '
    'Blocks shared → exclusive if overlapping future blocks exist. '
    'Uses FOR UPDATE on rooms row to serialize against concurrent block creation.';


-- =============================================================================
-- SECTION 3 — ROOM CAPACITY ENFORCEMENT TRIGGER (dual-mode)
-- =============================================================================
-- Fires on INSERT/UPDATE of schedule_blocks when room_id is set.
-- Reads room_policy and dispatches to appropriate enforcement model.
-- FOR UPDATE on rooms row serializes concurrent block insertions.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_room_capacity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_room_policy       TEXT;
    v_room_capacity     INTEGER;
    v_this_id           UUID;
    v_overlap_count     INTEGER;
    v_overlap_load      INTEGER;
BEGIN
    -- Only relevant when room_id is set
    IF NEW.room_id IS NULL THEN RETURN NEW; END IF;

    -- Only active blocks consume room capacity
    IF NEW.block_status IN ('cancelled','completed') THEN RETURN NEW; END IF;

    -- Lock room row — serializes concurrent INSERT/UPDATE on same room
    SELECT room_policy, capacity
    INTO v_room_policy, v_room_capacity
    FROM rooms
    WHERE id = NEW.room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'room % not found.', NEW.room_id;
    END IF;

    -- Self-exclusion ID for UPDATE (on INSERT, id is already set via generate_uuidv7())
    v_this_id := COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID);

    -- ── Exclusive model ───────────────────────────────────────────────────────
    IF v_room_policy = 'exclusive' THEN
        SELECT COUNT(*) INTO v_overlap_count
        FROM schedule_blocks
        WHERE room_id     = NEW.room_id
          AND id          != v_this_id
          AND block_status NOT IN ('cancelled','completed')
          AND tstzrange(scheduled_start, scheduled_end, '[)')
              && tstzrange(NEW.scheduled_start, NEW.scheduled_end, '[)');

        IF v_overlap_count > 0 THEN
            RAISE EXCEPTION
                '[D-RC1] Room % is exclusive — only one block per time window. '
                '% overlapping active block(s) found for the requested time range.',
                NEW.room_id, v_overlap_count;
        END IF;

        -- Block capacity must not exceed room capacity (sanity check)
        IF NEW.capacity > v_room_capacity THEN
            RAISE EXCEPTION
                'Block capacity (%) exceeds exclusive room % physical capacity (%). '
                'Reduce block capacity or use a larger room.',
                NEW.capacity, NEW.room_id, v_room_capacity;
        END IF;

        RETURN NEW;
    END IF;

    -- ── Shared model ──────────────────────────────────────────────────────────
    IF v_room_policy = 'shared' THEN
        -- Sum capacity of all overlapping active blocks (excluding this one)
        SELECT COALESCE(SUM(sb.capacity), 0) INTO v_overlap_load
        FROM schedule_blocks sb
        WHERE sb.room_id     = NEW.room_id
          AND sb.id          != v_this_id
          AND sb.block_status NOT IN ('cancelled','completed')
          AND tstzrange(sb.scheduled_start, sb.scheduled_end, '[)')
              && tstzrange(NEW.scheduled_start, NEW.scheduled_end, '[)');

        IF (v_overlap_load + NEW.capacity) > v_room_capacity THEN
            RAISE EXCEPTION
                '[D-RC1] Shared room % capacity exceeded. '
                'Room capacity: %. Existing overlapping load: %. '
                'This block requests: %. Total would be: % (exceeds room capacity by %).',
                NEW.room_id,
                v_room_capacity,
                v_overlap_load,
                NEW.capacity,
                v_overlap_load + NEW.capacity,
                (v_overlap_load + NEW.capacity) - v_room_capacity;
        END IF;

        RETURN NEW;
    END IF;

    -- Unknown policy (should not be reachable given CHECK constraint)
    RAISE EXCEPTION 'Unknown room_policy % for room %.', v_room_policy, NEW.room_id;
END;
$$;

CREATE TRIGGER trg_room_capacity
    BEFORE INSERT OR UPDATE OF room_id, scheduled_start, scheduled_end, capacity, block_status
    ON schedule_blocks
    FOR EACH ROW EXECUTE FUNCTION enforce_room_capacity();

COMMENT ON TRIGGER trg_room_capacity ON schedule_blocks IS
    '[D-RC1] Dual-mode room capacity enforcement. '
    'exclusive: one block per room per time window. '
    '  Also enforces block.capacity ≤ room.capacity. '
    'shared: SUM(overlapping block.capacity) ≤ room.capacity [D-RC2]. '
    '  Predictive model — enforced at scheduling time, not participant fill. '
    'FOR UPDATE on rooms row prevents concurrent block insertions from both passing. '
    'Fires on INSERT and UPDATE of scheduling-relevant columns. '
    'Cancelled/completed blocks excluded from capacity calculation.';


-- =============================================================================
-- SECTION 4 — CO-PROVIDER OVERLAP ENFORCEMENT
-- =============================================================================
-- Primary provider double-booking: already prevented by excl_provider_no_overlap
-- (EXCLUSION CONSTRAINT on schedule_blocks, Phase 4, Section 4).
--
-- Co-provider double-booking: must be checked via trigger.
-- A co-provider (in schedule_block_providers) cannot overlap with any block
-- where they are primary_provider OR another co-provider.
-- PostgreSQL EXCLUDE cannot reference other tables in its predicate —
-- trigger is the correct enforcement mechanism here.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_co_provider_no_overlap()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_new_start     TIMESTAMPTZ;
    v_new_end       TIMESTAMPTZ;
    v_new_inst      UUID;
    v_conflict_block UUID;
    v_conflict_role  TEXT;
BEGIN
    -- Get the block's time range and institute
    SELECT scheduled_start, scheduled_end, institute_id
    INTO v_new_start, v_new_end, v_new_inst
    FROM schedule_blocks
    WHERE id = NEW.schedule_block_id;

    -- Check 1: co-provider is primary_provider of another overlapping block
    SELECT id INTO v_conflict_block
    FROM schedule_blocks
    WHERE primary_provider_id = NEW.provider_id
      AND institute_id        = v_new_inst
      AND id                 != NEW.schedule_block_id
      AND block_status        NOT IN ('cancelled','completed')
      AND tstzrange(scheduled_start, scheduled_end, '[)')
          && tstzrange(v_new_start, v_new_end, '[)')
    LIMIT 1;

    IF v_conflict_block IS NOT NULL THEN
        v_conflict_role := 'primary_provider';
        RAISE EXCEPTION
            '[D-RC3] Co-provider % has an overlapping block (%) as primary_provider. '
            'A provider cannot be in two overlapping blocks in any role.',
            NEW.provider_id, v_conflict_block;
    END IF;

    -- Check 2: co-provider is co-provider of another overlapping block
    SELECT sbp.schedule_block_id INTO v_conflict_block
    FROM schedule_block_providers sbp
    JOIN schedule_blocks sb ON sb.id = sbp.schedule_block_id
    WHERE sbp.provider_id        = NEW.provider_id
      AND sbp.schedule_block_id != NEW.schedule_block_id
      AND sb.institute_id        = v_new_inst
      AND sb.block_status        NOT IN ('cancelled','completed')
      AND tstzrange(sb.scheduled_start, sb.scheduled_end, '[)')
          && tstzrange(v_new_start, v_new_end, '[)')
    LIMIT 1;

    IF v_conflict_block IS NOT NULL THEN
        RAISE EXCEPTION
            '[D-RC3] Co-provider % is already a co-provider on overlapping block %. '
            'A provider cannot be in two overlapping blocks in any role.',
            NEW.provider_id, v_conflict_block;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_co_provider_no_overlap
    BEFORE INSERT ON schedule_block_providers
    FOR EACH ROW EXECUTE FUNCTION enforce_co_provider_no_overlap();

COMMENT ON TRIGGER trg_co_provider_no_overlap ON schedule_block_providers IS
    '[D-RC3] Co-provider double-booking prevention. '
    'Checks both: co-provider as primary_provider elsewhere, '
    '  AND co-provider in another schedule_block_providers row. '
    'Primary provider overlap already prevented by excl_provider_no_overlap '
    '  on schedule_blocks (Phase 4, EXCLUSION CONSTRAINT). '
    'Trigger is correct mechanism here: EXCLUDE cannot reference other tables.';


-- =============================================================================
-- SECTION 5 — BLOCK CAPACITY vs ROOM CAPACITY CONSISTENCY
-- =============================================================================
-- When room_id is set and block is first created, block.capacity must
-- not exceed room.capacity. Enforced inside enforce_room_capacity() for
-- exclusive rooms explicitly, and implicitly for shared rooms (0 existing
-- load + NEW.capacity ≤ room.capacity).
--
-- Additional guard: room.capacity cannot be reduced below the maximum
-- block.capacity of any active block currently assigned to the room.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_room_capacity_reduction()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_max_block_cap INTEGER;
    v_total_peak    INTEGER;
BEGIN
    -- Only relevant if capacity is being reduced
    IF NEW.capacity >= OLD.capacity THEN RETURN NEW; END IF;

    -- For exclusive rooms: no block.capacity may exceed new room.capacity
    IF NEW.room_policy = 'exclusive' THEN
        SELECT COALESCE(MAX(capacity), 0) INTO v_max_block_cap
        FROM schedule_blocks
        WHERE room_id     = NEW.id
          AND block_status NOT IN ('cancelled','completed');

        IF v_max_block_cap > NEW.capacity THEN
            RAISE EXCEPTION
                'Cannot reduce room % capacity to % — active block has capacity % '
                'which would exceed the new room capacity.',
                NEW.id, NEW.capacity, v_max_block_cap;
        END IF;
    END IF;

    -- For shared rooms: peak load of overlapping blocks must not exceed new capacity
    -- (simplified check: total capacity of all active blocks must fit)
    IF NEW.room_policy = 'shared' THEN
        SELECT COALESCE(SUM(capacity), 0) INTO v_total_peak
        FROM schedule_blocks
        WHERE room_id     = NEW.id
          AND block_status NOT IN ('cancelled','completed');

        IF v_total_peak > NEW.capacity THEN
            RAISE EXCEPTION
                'Cannot reduce shared room % capacity to % — '
                'total capacity of active blocks (%) would exceed new room capacity.',
                NEW.id, NEW.capacity, v_total_peak;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_room_capacity_reduction
    BEFORE UPDATE OF capacity ON rooms
    FOR EACH ROW EXECUTE FUNCTION enforce_room_capacity_reduction();

COMMENT ON TRIGGER trg_room_capacity_reduction ON rooms IS
    'Guards room.capacity reduction. '
    'exclusive: no active block.capacity may exceed new room capacity. '
    'shared: simplified check — total active block capacity must fit. '
    'Prevents retroactive capacity violations on already-scheduled blocks.';


-- =============================================================================
-- SECTION 6 — MIGRATION PRE-CHECK QUERY
-- =============================================================================
-- Run BEFORE applying this file in environments with existing schedule_blocks data.
-- Identifies blocks that would violate the new room constraints.
-- =============================================================================

COMMENT ON FUNCTION enforce_room_capacity() IS
    '[D-RC1] Dual-mode room capacity enforcement trigger. '
    'MIGRATION NOTE: Before applying this file to existing data, run: '
    '' ||
    'SELECT sb1.id AS block_1, sb2.id AS block_2, sb1.room_id, '
    '       r.room_policy, r.capacity AS room_cap, '
    '       sb1.capacity AS cap_1, sb2.capacity AS cap_2 '
    'FROM schedule_blocks sb1 '
    'JOIN schedule_blocks sb2 ON sb2.room_id = sb1.room_id '
    '    AND sb2.id > sb1.id '
    'JOIN rooms r ON r.id = sb1.room_id '
    'WHERE sb1.block_status NOT IN (''cancelled'',''completed'') '
    '  AND sb2.block_status NOT IN (''cancelled'',''completed'') '
    '  AND tstzrange(sb1.scheduled_start, sb1.scheduled_end, ''[)'') '
    '      && tstzrange(sb2.scheduled_start, sb2.scheduled_end, ''[)'') '
    'ORDER BY sb1.room_id, sb1.scheduled_start; '
    '' ||
    'Resolve any conflicts before applying triggers.';

-- Standalone pre-check view (for DBA use during migration)
CREATE VIEW v_room_scheduling_conflicts AS
SELECT
    sb1.id              AS block_1_id,
    sb2.id              AS block_2_id,
    sb1.room_id,
    r.room_policy,
    r.capacity          AS room_capacity,
    sb1.capacity        AS block_1_capacity,
    sb2.capacity        AS block_2_capacity,
    sb1.capacity + sb2.capacity AS combined_load,
    sb1.scheduled_start AS block_1_start,
    sb1.scheduled_end   AS block_1_end,
    sb2.scheduled_start AS block_2_start,
    sb2.scheduled_end   AS block_2_end,
    CASE
        WHEN r.room_policy = 'exclusive'
            THEN 'CONFLICT: exclusive room has overlapping blocks'
        WHEN sb1.capacity + sb2.capacity > r.capacity
            THEN 'CONFLICT: shared room capacity exceeded'
        ELSE 'OK'
    END                 AS conflict_type
FROM schedule_blocks sb1
JOIN schedule_blocks sb2
    ON sb2.room_id = sb1.room_id
    AND sb2.id > sb1.id  -- avoid self-join and duplicates
JOIN rooms r ON r.id = sb1.room_id
WHERE sb1.block_status NOT IN ('cancelled','completed')
  AND sb2.block_status NOT IN ('cancelled','completed')
  AND tstzrange(sb1.scheduled_start, sb1.scheduled_end, '[)')
      && tstzrange(sb2.scheduled_start, sb2.scheduled_end, '[)');

COMMENT ON VIEW v_room_scheduling_conflicts IS
    'DBA migration pre-check view. '
    'Run SELECT * FROM v_room_scheduling_conflicts WHERE conflict_type != ''OK'' '
    'before applying phase5_room_capacity.sql to identify data that would '
    'violate the new room enforcement triggers. '
    'Resolve conflicts (cancel or reassign conflicting blocks) before migration.';


-- =============================================================================
-- SECTION 7 — SUPPORTING INDEX
-- =============================================================================

-- Index to support room capacity queries (overlapping block lookups)
CREATE INDEX idx_sb_room_active ON schedule_blocks(room_id, scheduled_start, scheduled_end)
    WHERE room_id IS NOT NULL
      AND block_status NOT IN ('cancelled','completed');

COMMENT ON INDEX idx_sb_room_active IS
    'Supports enforce_room_capacity() trigger: room overlap queries. '
    'Partial index excludes cancelled/completed blocks (same filter used in trigger). '
    'Critical for performance on busy shared rooms.';


-- =============================================================================
-- PHASE 5 ROOM CAPACITY — FINAL INVENTORY
-- =============================================================================
--
-- Schema changes (non-destructive):
--   rooms.room_policy           TEXT column ADDED ('exclusive'|'shared', default 'exclusive')
--   rooms.chk_room_policy       CHECK constraint ADDED
--   rooms.chk_room_capacity_positive CHECK ADDED
--   idx_sb_room_active          partial index on schedule_blocks ADDED
--   v_room_scheduling_conflicts migration pre-check view ADDED
--
-- Triggers (4):
--   trg_room_policy_change      guards room_policy mutation [D-RC4]
--   trg_room_capacity           dual-mode room enforcement [D-RC1] [D-RC2]
--   trg_co_provider_no_overlap  co-provider double-booking [D-RC3]
--   trg_room_capacity_reduction guards room.capacity reduction
--
-- Enforcement model:
--   exclusive rooms → trigger (not EXCLUSION — room_policy lives on rooms table)
--   shared rooms    → trigger SUM(block.capacity) ≤ room.capacity
--   Concurrency safety → FOR UPDATE on rooms row in both models
--
-- What is NOT changed:
--   schedule_blocks structure (no schema change)
--   schedule_block_providers structure (Phase 4 table, no change)
--   Primary provider overlap (excl_provider_no_overlap, Phase 4, unchanged)
--   Any Phase 1-4 trigger or constraint
--
-- =============================================================================
-- COMPLETE PHASE 5 MIGRATION SEQUENCE
-- =============================================================================
--   phase5_audit_log.sql          — audit table, trigger, helpers
--   phase5_audit_log_patch01.sql  — search_path hardening
--   phase5_room_capacity.sql      — dual-mode room enforcement  ← this file
--   phase5_reporting.sql          — materialized KPI views (next)
-- =============================================================================
--
-- SYSTEM STATUS: PHASES 1–5 (excl. reporting) PRODUCTION-FROZEN
-- =============================================================================
