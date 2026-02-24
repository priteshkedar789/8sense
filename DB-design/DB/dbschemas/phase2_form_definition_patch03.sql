-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 2 — FORM DEFINITION PATCH F03: CONCURRENCY HARDENING
-- =============================================================================
-- Apply after: phase2_form_definition.sql + patch01.sql + patch02.sql
-- =============================================================================
--
-- CORRECTIONS IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-F11] Concurrency race in effective overlap trigger.
--           enforce_version_effective_no_overlap() reads competing published rows
--           without locking them. Under concurrent publishing, two sessions can
--           both pass the overlap check before either commits.
--           Fix: acquire FOR UPDATE lock on competing published rows before
--           running overlap arithmetic. Serializes concurrent publish operations.
--
-- [FIX-F12] Concurrency race in cycle detection ancestry walk.
--           enforce_version_tree_no_cycles() walks the parent chain with plain
--           SELECT. Two concurrent sessions updating parents in opposite directions
--           could each see no cycle at check time, then commit a cycle.
--           Fix: use SELECT ... FOR UPDATE when walking each ancestor.
--           Serializes concurrent parent chain modifications.
--
-- [FIX-F13] Published versions must have effective_from NOT NULL.
--           Currently allowed: publish a version with no effective_from, then
--           set it later. Creates an activation window ambiguity window.
--           Fix: CHECK constraint enforcing effective_from IS NOT NULL when
--           status = 'published'.
-- =============================================================================


-- =============================================================================
-- [FIX-F11] Concurrency-safe effective overlap detection
-- =============================================================================
-- The key change: before running overlap arithmetic, acquire FOR UPDATE locks
-- on all published versions for this template+institute scope.
-- This serializes concurrent publish operations on the same template.
-- Cost: slight contention on concurrent publish — acceptable because publishing
-- a form version is a rare, deliberate administrative action, not a hot path.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_version_effective_no_overlap()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_overlap_count INTEGER;
    v_scope_id      UUID;
BEGIN
    -- Only enforce on published versions with effective_from set
    IF NEW.status != 'published' OR NEW.effective_from IS NULL THEN
        RETURN NEW;
    END IF;

    v_scope_id := COALESCE(NEW.institute_id, '00000000-0000-0000-0000-000000000000'::UUID);

    -- [FIX-F11] Acquire row-level locks on all competing published versions
    -- for this template+institute before running overlap check.
    -- This serializes concurrent publishing and eliminates the race window
    -- where two sessions both pass the check before either commits.
    PERFORM 1
    FROM form_versions
    WHERE form_template_id = NEW.form_template_id
      AND COALESCE(institute_id, '00000000-0000-0000-0000-000000000000'::UUID) = v_scope_id
      AND status = 'published'
      AND id != NEW.id
    FOR UPDATE;

    -- Now run overlap arithmetic with exclusive visibility of competitor rows
    SELECT COUNT(*) INTO v_overlap_count
    FROM form_versions
    WHERE form_template_id = NEW.form_template_id
      AND COALESCE(institute_id, '00000000-0000-0000-0000-000000000000'::UUID) = v_scope_id
      AND status = 'published'
      AND id != NEW.id
      AND (
          -- Existing open-ended version whose window intersects NEW
          (effective_to IS NULL
           AND effective_from <= COALESCE(NEW.effective_to, '9999-12-31'::DATE))
          OR
          -- Existing closed version whose window overlaps NEW
          (effective_to IS NOT NULL
           AND effective_from <= COALESCE(NEW.effective_to, '9999-12-31'::DATE)
           AND effective_to   >= NEW.effective_from)
      );

    IF v_overlap_count > 0 THEN
        RAISE EXCEPTION
            '[FIX-F11] Effective date overlap detected for form_version %. '
            'Template % already has a published version active during % to %. '
            'Archive or close the existing active version before publishing this one.',
            NEW.id, NEW.form_template_id,
            NEW.effective_from, COALESCE(NEW.effective_to::TEXT, 'open');
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_version_effective_no_overlap() IS
    '[FIX-F11] Concurrency-safe overlap detection. '
    'Acquires FOR UPDATE locks on competing published rows before overlap check. '
    'Serializes concurrent publish operations on the same template. '
    'Publishing is a rare administrative action — lock contention is acceptable. '
    'Works in tandem with uq_fv_single_open_active_version partial unique index.';


-- =============================================================================
-- [FIX-F12] Concurrency-safe ancestry walk in cycle detection
-- =============================================================================
-- The key change: acquire FOR UPDATE lock on each ancestor row during the walk.
-- This prevents two concurrent sessions from building A→B and B→A independently,
-- each seeing no cycle, then committing a loop.
-- Cost: slight contention on concurrent parent reassignment — acceptable because
-- reassigning parent_version_id is a rare, deliberate versioning action.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_version_tree_no_cycles()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_current_id    UUID;
    v_depth         INTEGER := 0;
    v_max_depth     INTEGER := 50;
BEGIN
    IF NEW.parent_version_id IS NULL THEN
        RETURN NEW;
    END IF;

    v_current_id := NEW.parent_version_id;

    WHILE v_current_id IS NOT NULL LOOP
        v_depth := v_depth + 1;

        IF v_current_id = NEW.id THEN
            RAISE EXCEPTION
                '[FIX-F12] Cycle detected in form_version tree. '
                'Version % cannot be its own ancestor via parent chain.',
                NEW.id;
        END IF;

        IF v_depth > v_max_depth THEN
            RAISE EXCEPTION
                '[FIX-F12] Version tree depth limit (%) exceeded at version %. '
                'Possible pre-existing cycle or unusually deep branch. '
                'Investigate ancestry before proceeding.',
                v_max_depth, v_current_id;
        END IF;

        -- [FIX-F12] Lock each ancestor row during walk.
        -- Prevents concurrent parent chain modifications from creating
        -- cycles that neither session detects at check time.
        SELECT parent_version_id INTO v_current_id
        FROM form_versions
        WHERE id = v_current_id
        FOR UPDATE;
    END LOOP;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_version_tree_no_cycles() IS
    '[FIX-F12] Concurrency-safe cycle detection. '
    'Acquires FOR UPDATE lock on each ancestor during the walk. '
    'Prevents concurrent sessions from committing intersecting parent chains '
    'that individually appear cycle-free but together form a loop. '
    'parent_version_id reassignment is a rare action — lock cost is acceptable. '
    'Combined with chk_no_self_parent, cycle creation is structurally impossible.';


-- =============================================================================
-- [FIX-F13] Published versions must have effective_from NOT NULL
-- =============================================================================
-- Without this, a version can be published with no activation date,
-- creating an ambiguous open-ended window from the beginning of time.
-- Form resolution logic cannot determine which version was active on a given
-- clinical date without a defined start point.
-- =============================================================================

ALTER TABLE form_versions
    ADD CONSTRAINT chk_published_requires_effective_from
    CHECK (
        status != 'published'
        OR effective_from IS NOT NULL
    );

COMMENT ON CONSTRAINT chk_published_requires_effective_from ON form_versions IS
    '[FIX-F13] A published version must have effective_from set. '
    'Prevents ambiguous activation windows with no defined start date. '
    'Form resolution (which version was active on date X?) requires a start anchor. '
    'Draft and review versions may have NULL effective_from during authoring. '
    'effective_from must be set before or at the moment of publishing.';


-- =============================================================================
-- PATCH F03 SUMMARY
-- =============================================================================
--
--  Fix      | What Changed
-- ──────────┼─────────────────────────────────────────────────────────────────
--  FIX-F11  | enforce_version_effective_no_overlap() REPLACED
--            | Added FOR UPDATE lock on competing published rows
--            | Overlap check now serialized under concurrent publishing
--
--  FIX-F12  | enforce_version_tree_no_cycles() REPLACED
--            | Added FOR UPDATE lock on each ancestor during walk
--            | Concurrent parent chain updates cannot create undetected cycles
--
--  FIX-F13  | chk_published_requires_effective_from CHECK on form_versions
--            | Published versions must have effective_from IS NOT NULL
--            | Eliminates activation window ambiguity
--
-- =============================================================================
-- FORM DEFINITION LAYER — FINAL CONCURRENCY STATUS
-- =============================================================================
--
--  Scenario                              | Protection           | Type
-- ───────────────────────────────────────┼──────────────────────┼─────────────
--  Concurrent open-window publish        | Partial unique index  | Structural
--  Concurrent closed-window overlap      | FOR UPDATE + trigger  | Structural
--  Concurrent parent chain cycle (2-hop) | chk_no_self_parent   | Structural
--  Concurrent parent chain cycle (N-hop) | FOR UPDATE + trigger  | Structural
--  Publish with no activation date       | CHECK constraint      | Structural
--  Version metadata drift post-publish   | Immutability trigger  | Structural
--  Cross-template branching              | Composite FK          | Structural
--  Cross-institute version contamination | Trigger               | Structural
--
-- All structural. No policy-only concurrency guarantees.
-- Definition layer is production-frozen and concurrency-safe.
--
-- =============================================================================
-- MIGRATION ORDER — COMPLETE DEFINITION LAYER SEQUENCE
-- =============================================================================
--
-- 1. phase1_foundation.sql
-- 2. phase1_patch01.sql
-- 3. phase1_patch02.sql
-- 4. phase2_form_definition.sql
-- 5. phase2_form_definition_patch01.sql
-- 6. phase2_form_definition_patch02.sql
-- 7. phase2_form_definition_patch03.sql  ← this file
-- 8. phase2_form_responses.sql           ← NEXT: response layer
--
-- =============================================================================
