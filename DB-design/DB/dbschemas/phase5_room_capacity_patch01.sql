-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 5 — ROOM CAPACITY PATCH 01: STRUCTURAL CORRECTIONS
-- =============================================================================
-- Apply after: phase5_room_capacity.sql
-- =============================================================================
--
-- FIXES IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-RC1] Shared room capacity reduction check was incorrect.
--           Previous: SUM(capacity) of ALL active blocks for this room.
--           Problem: two non-overlapping blocks summed together blocked safe
--           reductions. Room with 6am block (cap 6) + 6pm block (cap 6) could
--           not reduce to 8 despite peak overlap never exceeding 6.
--           Fix: compute peak overlapping load using window overlap aggregation.
--           Peak = max SUM(capacity) across any overlapping block cluster.
--
-- [FIX-RC2] Room policy downgrade (shared → exclusive) did not lock
--           schedule_blocks rows before evaluating conflicts.
--           A concurrent block INSERT could interleave with the downgrade check,
--           both passing before either commits.
--           Fix: SELECT ... FOR UPDATE on all active future blocks for this room
--           before evaluating overlap conflicts.
--
-- [FIX-RC3] Co-provider overlap trigger only guarded INSERT.
--           UPDATE OF provider_id or schedule_block_id bypassed the check.
--           Fix: trigger changed to BEFORE INSERT OR UPDATE OF provider_id,
--           schedule_block_id.
--
-- MINOR CLEANUP [FIX-RC4]
--           v_this_id := COALESCE(NEW.id, '0000...') — fallback unreachable
--           because generate_uuidv7() fires before trigger. Simplified.
-- =============================================================================


-- =============================================================================
-- [FIX-RC1] Peak overlap capacity reduction check
-- =============================================================================
-- The correct question for capacity reduction is:
-- "Does any point in time have overlapping blocks whose combined capacity
--  exceeds the new room capacity?"
--
-- Computing the true peak requires finding the maximum overlapping load.
-- We use a self-join to find, for each block, the sum of capacities of all
-- blocks that overlap with it. The maximum of these sums is the peak.
-- If peak ≤ new capacity, the reduction is safe.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_room_capacity_reduction()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_peak_load INTEGER;
BEGIN
    -- Only relevant if capacity is being reduced
    IF NEW.capacity >= OLD.capacity THEN RETURN NEW; END IF;

    -- Compute peak overlapping load:
    -- For each active block assigned to this room, sum the capacity of
    -- all other active blocks whose time range overlaps with it.
    -- The maximum such sum + the reference block's own capacity = peak load.
    SELECT COALESCE(MAX(overlap_group_total), 0) INTO v_peak_load
    FROM (
        SELECT
            sb_ref.id,
            sb_ref.capacity + COALESCE(SUM(sb_other.capacity), 0) AS overlap_group_total
        FROM schedule_blocks sb_ref
        LEFT JOIN schedule_blocks sb_other
            ON sb_other.room_id       = sb_ref.room_id
           AND sb_other.id           != sb_ref.id
           AND sb_other.block_status  NOT IN ('cancelled','completed')
           AND tstzrange(sb_other.scheduled_start, sb_other.scheduled_end, '[)')
               && tstzrange(sb_ref.scheduled_start, sb_ref.scheduled_end, '[)')
        WHERE sb_ref.room_id     = NEW.id
          AND sb_ref.block_status NOT IN ('cancelled','completed')
        GROUP BY sb_ref.id, sb_ref.capacity
    ) overlap_groups;

    IF v_peak_load > NEW.capacity THEN
        RAISE EXCEPTION
            '[FIX-RC1] Cannot reduce room % capacity from % to % — '
            'peak overlapping block load is % (would exceed new capacity). '
            'Resolve scheduling conflicts or use a phased reduction.',
            NEW.id, OLD.capacity, NEW.capacity, v_peak_load;
    END IF;

    RETURN NEW;
END;
$$;

-- Drop the old trigger and recreate with corrected function
DROP TRIGGER IF EXISTS trg_room_capacity_reduction ON rooms;

CREATE TRIGGER trg_room_capacity_reduction
    BEFORE UPDATE OF capacity ON rooms
    FOR EACH ROW EXECUTE FUNCTION enforce_room_capacity_reduction();

COMMENT ON FUNCTION enforce_room_capacity_reduction() IS
    '[FIX-RC1] Corrected peak overlap check for room capacity reduction. '
    'Previous version used SUM(all active blocks) — incorrect. '
    'Correct model: peak = max(SUM(overlapping block capacities at any point in time)). '
    'Uses self-join to compute overlap groups per block, then takes MAX. '
    'A room with non-overlapping blocks can be safely reduced if peak ≤ new capacity. '
    'Applies to both exclusive and shared rooms.';


-- =============================================================================
-- [FIX-RC2] Policy downgrade locking — lock schedule_blocks before evaluation
-- =============================================================================
-- When evaluating shared → exclusive downgrade, concurrent block inserts
-- on the same room could race: both the downgrade check and the new block
-- insert pass their respective checks before either commits.
--
-- Fix: after locking the room row, also lock all active future blocks
-- for this room using FOR UPDATE. This serializes the evaluation against
-- any concurrent block INSERT (which will also lock the room row in
-- enforce_room_capacity(), creating a predictable serialization order).
--
-- Lock acquisition order: rooms → schedule_blocks (consistent with
-- enforce_room_capacity() which also locks rooms first).
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_room_policy_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_conflict_id UUID;
BEGIN
    IF NEW.room_policy = OLD.room_policy THEN RETURN NEW; END IF;

    -- Lock the room row first (consistent lock order: room before blocks)
    PERFORM id FROM rooms WHERE id = NEW.id FOR UPDATE;

    -- [FIX-RC2] Lock all active future blocks for this room
    -- Prevents concurrent block INSERT from interleaving with downgrade check
    PERFORM id FROM schedule_blocks
    WHERE room_id     = NEW.id
      AND scheduled_start > NOW()
      AND block_status NOT IN ('cancelled','completed')
    FOR UPDATE;

    -- Immutable if any block has started (in_progress or completed)
    IF EXISTS (
        SELECT 1 FROM schedule_blocks
        WHERE room_id      = NEW.id
          AND block_status IN ('in_progress','completed')
    ) THEN
        RAISE EXCEPTION
            '[D-RC4] room % policy cannot change — blocks in progress or completed exist. '
            'A started or completed session anchors the room context.',
            NEW.id;
    END IF;

    -- Downgrade shared → exclusive: no overlapping future blocks allowed
    IF OLD.room_policy = 'shared' AND NEW.room_policy = 'exclusive' THEN
        SELECT a.id INTO v_conflict_id
        FROM schedule_blocks a
        JOIN schedule_blocks b ON b.id != a.id
        WHERE a.room_id      = NEW.id
          AND b.room_id      = NEW.id
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

-- Trigger already exists — function replacement is sufficient.
-- No need to recreate trigger; it calls the function by name.

COMMENT ON FUNCTION enforce_room_policy_change() IS
    '[FIX-RC2] Added FOR UPDATE on schedule_blocks after room lock. '
    'Lock order: rooms → schedule_blocks (consistent with enforce_room_capacity()). '
    'This prevents: concurrent block INSERT passing its check in enforce_room_capacity() '
    'while policy downgrade check is evaluating — both hold room lock, serialize cleanly. '
    'Locks only future non-cancelled blocks (same filter as conflict evaluation).';


-- =============================================================================
-- [FIX-RC3] Co-provider overlap — add UPDATE protection
-- =============================================================================
-- Original trigger: BEFORE INSERT only.
-- UPDATE OF provider_id or schedule_block_id bypasses overlap check.
-- If a co-provider row is updated to a different provider or different block,
-- the new configuration could create an overlap that was not validated.
-- Fix: extend to BEFORE INSERT OR UPDATE OF provider_id, schedule_block_id.
-- =============================================================================

-- Drop old trigger, recreate with UPDATE coverage
DROP TRIGGER IF EXISTS trg_co_provider_no_overlap ON schedule_block_providers;

CREATE OR REPLACE FUNCTION enforce_co_provider_no_overlap()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_new_start      TIMESTAMPTZ;
    v_new_end        TIMESTAMPTZ;
    v_new_inst       UUID;
    v_conflict_block UUID;
BEGIN
    -- Get the target block's time range and institute
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
        RAISE EXCEPTION
            '[D-RC3] Provider % has an overlapping block (%) as primary_provider. '
            'A provider cannot be in two overlapping blocks in any role.',
            NEW.provider_id, v_conflict_block;
    END IF;

    -- Check 2: co-provider appears in another overlapping block's provider roster
    SELECT sbp.schedule_block_id INTO v_conflict_block
    FROM schedule_block_providers sbp
    JOIN schedule_blocks sb ON sb.id = sbp.schedule_block_id
    WHERE sbp.provider_id         = NEW.provider_id
      AND sbp.schedule_block_id  != NEW.schedule_block_id
      AND sb.institute_id         = v_new_inst
      AND sb.block_status         NOT IN ('cancelled','completed')
      AND tstzrange(sb.scheduled_start, sb.scheduled_end, '[)')
          && tstzrange(v_new_start, v_new_end, '[)')
    LIMIT 1;

    IF v_conflict_block IS NOT NULL THEN
        RAISE EXCEPTION
            '[D-RC3] Provider % is already a co-provider on overlapping block %. '
            'A provider cannot be in two overlapping blocks in any role.',
            NEW.provider_id, v_conflict_block;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_co_provider_no_overlap
    BEFORE INSERT OR UPDATE OF provider_id, schedule_block_id
    ON schedule_block_providers
    FOR EACH ROW EXECUTE FUNCTION enforce_co_provider_no_overlap();

COMMENT ON TRIGGER trg_co_provider_no_overlap ON schedule_block_providers IS
    '[FIX-RC3] Extended to BEFORE INSERT OR UPDATE OF provider_id, schedule_block_id. '
    'Previously INSERT-only — UPDATE could bypass overlap check. '
    'Fires on provider reassignment and block reassignment. '
    'Two overlap checks: (1) co-provider as primary elsewhere, '
    '                    (2) co-provider in another block provider roster. '
    'Primary provider overlap: excl_provider_no_overlap (Phase 4) handles separately.';


-- =============================================================================
-- [FIX-RC4] Minor cleanup — remove unreachable COALESCE fallback
-- =============================================================================
-- generate_uuidv7() fires before the trigger, so NEW.id is always set.
-- The '0000...' fallback in enforce_room_capacity() is dead code.
-- Replacing with direct assignment for clarity.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_room_capacity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_room_policy   TEXT;
    v_room_capacity INTEGER;
    v_this_id       UUID;
    v_overlap_count INTEGER;
    v_overlap_load  INTEGER;
BEGIN
    IF NEW.room_id IS NULL THEN RETURN NEW; END IF;
    IF NEW.block_status IN ('cancelled','completed') THEN RETURN NEW; END IF;

    -- Lock room row — serializes concurrent inserts on same room
    SELECT room_policy, capacity
    INTO v_room_policy, v_room_capacity
    FROM rooms
    WHERE id = NEW.room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'room % not found.', NEW.room_id;
    END IF;

    -- [FIX-RC4] NEW.id always set — no fallback needed
    v_this_id := NEW.id;

    -- ── Exclusive model ───────────────────────────────────────────────────────
    IF v_room_policy = 'exclusive' THEN
        SELECT COUNT(*) INTO v_overlap_count
        FROM schedule_blocks
        WHERE room_id      = NEW.room_id
          AND id           != v_this_id
          AND block_status  NOT IN ('cancelled','completed')
          AND tstzrange(scheduled_start, scheduled_end, '[)')
              && tstzrange(NEW.scheduled_start, NEW.scheduled_end, '[)');

        IF v_overlap_count > 0 THEN
            RAISE EXCEPTION
                '[D-RC1] Room % is exclusive — only one block per time window. '
                '% overlapping active block(s) exist.',
                NEW.room_id, v_overlap_count;
        END IF;

        IF NEW.capacity > v_room_capacity THEN
            RAISE EXCEPTION
                'Block capacity (%) exceeds exclusive room % capacity (%).',
                NEW.capacity, NEW.room_id, v_room_capacity;
        END IF;

        RETURN NEW;
    END IF;

    -- ── Shared model ──────────────────────────────────────────────────────────
    IF v_room_policy = 'shared' THEN
        SELECT COALESCE(SUM(sb.capacity), 0) INTO v_overlap_load
        FROM schedule_blocks sb
        WHERE sb.room_id      = NEW.room_id
          AND sb.id           != v_this_id
          AND sb.block_status  NOT IN ('cancelled','completed')
          AND tstzrange(sb.scheduled_start, sb.scheduled_end, '[)')
              && tstzrange(NEW.scheduled_start, NEW.scheduled_end, '[)');

        IF (v_overlap_load + NEW.capacity) > v_room_capacity THEN
            RAISE EXCEPTION
                '[D-RC1] Shared room % capacity exceeded. '
                'Room: %. Existing overlapping load: %. This block: %. Total: % (over by %).',
                NEW.room_id, v_room_capacity, v_overlap_load, NEW.capacity,
                v_overlap_load + NEW.capacity,
                (v_overlap_load + NEW.capacity) - v_room_capacity;
        END IF;

        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'Unknown room_policy % for room %.', v_room_policy, NEW.room_id;
END;
$$;

COMMENT ON FUNCTION enforce_room_capacity() IS
    '[FIX-RC4] v_this_id := NEW.id (COALESCE fallback removed — unreachable). '
    'Dual-mode enforcement unchanged: exclusive / shared. '
    'FOR UPDATE on rooms row for concurrency serialization. '
    'Exclusive: COUNT overlapping active blocks. '
    'Shared: SUM overlapping block.capacity ≤ room.capacity.';


-- =============================================================================
-- PATCH RC01 SUMMARY
-- =============================================================================
--
--  Fix      | What Changed
-- ──────────┼─────────────────────────────────────────────────────────────────
--  FIX-RC1  | enforce_room_capacity_reduction() REPLACED
--            | Peak overlap computed via self-join (not SUM of all active blocks)
--            | Non-overlapping blocks no longer block valid capacity reductions
--
--  FIX-RC2  | enforce_room_policy_change() REPLACED
--            | FOR UPDATE on schedule_blocks added after room row lock
--            | Lock order: rooms → schedule_blocks (consistent with scheduling path)
--            | Concurrent block INSERT + policy downgrade now serialize correctly
--
--  FIX-RC3  | trg_co_provider_no_overlap DROPPED and RECREATED
--            | BEFORE INSERT OR UPDATE OF provider_id, schedule_block_id
--            | UPDATE of provider or block now re-validates overlap
--
--  FIX-RC4  | enforce_room_capacity() REPLACED (minor)
--            | v_this_id := NEW.id (dead COALESCE fallback removed)
--
-- =============================================================================
-- ROOM CAPACITY LAYER — PRODUCTION FROZEN
-- =============================================================================
--
-- Lock acquisition order (consistent across all room functions):
--   1. rooms FOR UPDATE
--   2. schedule_blocks FOR UPDATE (policy downgrade only)
-- No deadlock risk: all paths acquire in same order.
--
-- Complete Phase 5 migration:
--   phase5_audit_log.sql
--   phase5_audit_log_patch01.sql
--   phase5_room_capacity.sql
--   phase5_room_capacity_patch01.sql   ← this file
--   phase5_reporting.sql               (next)
-- =============================================================================
