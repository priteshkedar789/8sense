-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 2 — FORM DEFINITION PATCH F02: FINAL HARDENING
-- =============================================================================
-- Apply after: phase2_form_definition.sql + phase2_form_definition_patch01.sql
-- =============================================================================
--
-- CORRECTIONS IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-F8]  Version tree cycle detection.
--           Composite FK enforces same-template parent, but does not prevent
--           self-parenting or cyclic ancestry chains. Loops break version tree
--           traversal, effective version resolution, and migration scripts.
--           Fix: CHECK for self-parent + recursive ancestry trigger.
--
-- [FIX-F9]  Effective date overlap enforcement.
--           Two published versions for the same template+institute could have
--           overlapping effective windows. Clinical form resolution becomes
--           ambiguous. Fix: partial unique index on open-ended active window
--           + trigger for closed-window overlap detection.
--
-- [FIX-F10] Explicit DELETE RLS policy decision.
--           DELETE was previously blocked for all except platform_admin.
--           Decision locked: institutes may DELETE only draft versions and
--           their child records (fields, rules, logic). Published and archived
--           versions are permanently undeletable. Explicit DELETE policies added.
--
-- [ADJ-1]   choice_options score field validation when is_scored = TRUE.
--           If a field is marked is_scored and uses choice_options, each choice
--           element must carry a numeric "score" key. Silent absence breaks
--           computed scoring without error at response capture time.
--
-- [ADJ-2]   Global template mutability confirmation.
--           No schema change — confirmed and documented that the existing
--           ft_institute_update policy (institute_id = current_institute_id())
--           correctly excludes global templates (institute_id IS NULL).
-- =============================================================================


-- =============================================================================
-- [FIX-F8] Version tree cycle detection
-- =============================================================================
-- Two layers:
--   Layer 1: CHECK constraint blocks self-parenting (id = parent_version_id).
--            Fast, structural, zero overhead.
--   Layer 2: Trigger walks ancestry chain before INSERT/UPDATE.
--            Rejects if NEW.id appears anywhere in the parent chain.
--            Prevents multi-hop cycles (A→B→C→A).
-- =============================================================================

-- Layer 1: Self-parent prevention (cheap, structural)
ALTER TABLE form_versions
    ADD CONSTRAINT chk_no_self_parent
    CHECK (parent_version_id IS NULL OR parent_version_id != id);

COMMENT ON CONSTRAINT chk_no_self_parent ON form_versions IS
    '[FIX-F8] Layer 1: prevents a version referencing itself as parent. '
    'Layer 2 (trigger) handles multi-hop cycles.';

-- Layer 2: Recursive cycle detection
CREATE OR REPLACE FUNCTION enforce_version_tree_no_cycles()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_current_id    UUID;
    v_depth         INTEGER := 0;
    v_max_depth     INTEGER := 50;  -- sane depth limit; real trees rarely exceed 10
BEGIN
    -- Only check when parent_version_id is being set
    IF NEW.parent_version_id IS NULL THEN
        RETURN NEW;
    END IF;

    v_current_id := NEW.parent_version_id;

    WHILE v_current_id IS NOT NULL LOOP
        v_depth := v_depth + 1;

        -- Cycle detected: ancestor chain contains the version being inserted/updated
        IF v_current_id = NEW.id THEN
            RAISE EXCEPTION
                '[FIX-F8] Cycle detected in form_version tree. '
                'Version % cannot be its own ancestor via parent chain. '
                'This would corrupt version tree traversal and effective version resolution.',
                NEW.id;
        END IF;

        -- Depth guard: prevents infinite loop if somehow a cycle already exists
        IF v_depth > v_max_depth THEN
            RAISE EXCEPTION
                '[FIX-F8] Version tree depth limit (%) exceeded starting from version %. '
                'Possible pre-existing cycle or unusually deep branch. '
                'Investigate ancestry before proceeding.',
                v_max_depth, NEW.parent_version_id;
        END IF;

        -- Walk up one level
        SELECT parent_version_id INTO v_current_id
        FROM form_versions
        WHERE id = v_current_id;
    END LOOP;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_form_version_no_cycles
    BEFORE INSERT OR UPDATE OF parent_version_id
    ON form_versions
    FOR EACH ROW
    EXECUTE FUNCTION enforce_version_tree_no_cycles();

COMMENT ON TRIGGER trg_form_version_no_cycles ON form_versions IS
    '[FIX-F8] Layer 2: recursive ancestry walk before INSERT/UPDATE. '
    'Rejects if NEW.id appears anywhere in the parent chain. '
    'Depth limit of 50 prevents runaway loops. '
    'Combined with chk_no_self_parent, makes cycle creation structurally impossible.';


-- =============================================================================
-- [FIX-F9] Effective date overlap enforcement
-- =============================================================================
-- Two scenarios must be prevented:
--
--   Scenario A: Two open-ended active versions for same template+institute.
--               (effective_to IS NULL on both)
--               → Partial unique index handles this cleanly.
--
--   Scenario B: One closed version overlaps with another's window.
--               e.g. v1: 2024-01-01 → 2024-06-30
--                    v2: 2024-04-01 → NULL   (overlaps v1 by 3 months)
--               → Trigger handles this.
--
-- institute_id NULL (global versions) treated as its own scope.
-- =============================================================================

-- Scenario A: Only one open-ended (effective_to IS NULL) published version
-- per template+institute at any time.
CREATE UNIQUE INDEX uq_fv_single_open_active_version
    ON form_versions (form_template_id, COALESCE(institute_id, '00000000-0000-0000-0000-000000000000'::UUID))
    WHERE status = 'published' AND effective_to IS NULL;

COMMENT ON INDEX uq_fv_single_open_active_version IS
    '[FIX-F9] Scenario A: Only one currently-open published version per template+institute. '
    'COALESCE on nullable institute_id prevents NULL-distinct duplicate bypass. '
    'When publishing a new version, the old one must be archived or effective_to must be set first.';

-- Scenario B: No overlapping closed published version windows
CREATE OR REPLACE FUNCTION enforce_version_effective_no_overlap()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_overlap_count INTEGER;
    v_scope_id      UUID;
BEGIN
    -- Only enforce on published versions with effective dates
    IF NEW.status != 'published' OR NEW.effective_from IS NULL THEN
        RETURN NEW;
    END IF;

    -- Normalize institute_id for global versions
    v_scope_id := COALESCE(NEW.institute_id, '00000000-0000-0000-0000-000000000000'::UUID);

    SELECT COUNT(*) INTO v_overlap_count
    FROM form_versions
    WHERE form_template_id = NEW.form_template_id
      AND COALESCE(institute_id, '00000000-0000-0000-0000-000000000000'::UUID) = v_scope_id
      AND status = 'published'
      AND id != NEW.id
      AND (
          -- Existing open-ended version starts before NEW ends (or NEW is open-ended)
          (effective_to IS NULL AND effective_from <= COALESCE(NEW.effective_to, '9999-12-31'::DATE))
          OR
          -- Existing closed version overlaps with NEW window
          (effective_to IS NOT NULL
           AND effective_from <= COALESCE(NEW.effective_to, '9999-12-31'::DATE)
           AND effective_to   >= NEW.effective_from)
      );

    IF v_overlap_count > 0 THEN
        RAISE EXCEPTION
            '[FIX-F9] Effective date overlap detected for form_version %. '
            'Template % already has a published version active during the window '
            '% to %. '
            'Archive or close the existing active version before publishing this one.',
            NEW.id, NEW.form_template_id,
            NEW.effective_from, COALESCE(NEW.effective_to::TEXT, 'open');
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_form_version_effective_no_overlap
    BEFORE INSERT OR UPDATE OF status, effective_from, effective_to, institute_id
    ON form_versions
    FOR EACH ROW
    EXECUTE FUNCTION enforce_version_effective_no_overlap();

COMMENT ON TRIGGER trg_form_version_effective_no_overlap ON form_versions IS
    '[FIX-F9] Scenario B: prevents overlapping effective windows between published versions. '
    'Works with uq_fv_single_open_active_version (Scenario A). '
    'Together these ensure unambiguous clinical form resolution on any given date.';


-- =============================================================================
-- [FIX-F10] Explicit DELETE RLS policies
-- =============================================================================
-- Decision locked:
--   DRAFT versions and their child records may be deleted by institute form managers.
--   PUBLISHED and ARCHIVED versions are permanently undeletable.
--   This is a regulatory decision: published instruments are part of clinical record.
--   The trigger enforcement (immutability) is the structural lock.
--   RLS DELETE policies define who can attempt deletion of draft records.
-- =============================================================================

-- form_versions DELETE: only draft versions, by institute form managers
CREATE POLICY fv_institute_delete ON form_versions
    FOR DELETE
    USING (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_FORMS')
        AND status = 'draft'
    );

COMMENT ON POLICY fv_institute_delete ON form_versions IS
    '[FIX-F10] Institutes may delete DRAFT versions only. '
    'Published and archived versions are permanently undeletable via RLS + immutability trigger. '
    'Platform admin bypass exists via fv_platform_admin policy.';

-- form_fields DELETE: only if belonging to a draft version
CREATE POLICY ff_institute_delete ON form_fields
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = form_fields.form_version_id
              AND fv.institute_id = current_institute_id()
              AND fv.status = 'draft'
        )
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );

-- field_validation_rules DELETE: only if belonging to a draft version
CREATE POLICY fvr_institute_delete ON field_validation_rules
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = field_validation_rules.form_version_id
              AND fv.institute_id = current_institute_id()
              AND fv.status = 'draft'
        )
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );

-- conditional_logic_rules DELETE: only if belonging to a draft version
CREATE POLICY clr_institute_delete ON conditional_logic_rules
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = conditional_logic_rules.form_version_id
              AND fv.institute_id = current_institute_id()
              AND fv.status = 'draft'
        )
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );

COMMENT ON POLICY clr_institute_delete ON conditional_logic_rules IS
    '[FIX-F10] All child-record DELETE policies follow the same pattern: '
    'draft version membership + CAN_MANAGE_FORMS permission. '
    'Published/archived version records cannot be deleted by any institute user. '
    'Platform admin bypass exists on all tables via existing platform_admin policies.';


-- =============================================================================
-- [ADJ-1] choice_options score validation for scored fields
-- =============================================================================
-- When a field is marked is_scored = TRUE and uses choice_options,
-- each choice element must carry a numeric "score" key.
-- Without this, computed scoring silently returns NULL for missing scores.
-- Extend the existing enforce_choice_options_field_type_compatibility() function.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_choice_options_field_type_compatibility()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_type_code     TEXT;
    v_bad_element   JSONB;
BEGIN
    -- No choice_options set — nothing to validate
    IF NEW.choice_options IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT ft.code INTO v_type_code
    FROM form_field_types ft
    WHERE ft.id = NEW.field_type_id;

    -- Type must support choices
    IF v_type_code NOT IN ('single_choice', 'multi_choice', 'scale_likert') THEN
        RAISE EXCEPTION
            '[FIX-F6/ADJ-1] choice_options may not be set on field type %. '
            'Only single_choice, multi_choice, and scale_likert support discrete options. '
            'Field: %, Version: %.',
            v_type_code, NEW.id, NEW.form_version_id;
    END IF;

    -- Must be a JSON array
    IF jsonb_typeof(NEW.choice_options) != 'array' THEN
        RAISE EXCEPTION
            '[FIX-F6/ADJ-1] choice_options must be a JSON array. '
            'Expected: [{"code": "...", "label": "...", "score": <number>}]. '
            'Field: %, Version: %.',
            NEW.id, NEW.form_version_id;
    END IF;

    -- Each element must have "code" and "label"
    SELECT elem INTO v_bad_element
    FROM jsonb_array_elements(NEW.choice_options) elem
    WHERE elem->>'code' IS NULL OR elem->>'label' IS NULL
    LIMIT 1;

    IF v_bad_element IS NOT NULL THEN
        RAISE EXCEPTION
            '[FIX-F6/ADJ-1] Each choice_options element must have "code" and "label". '
            'Offending element: %. Field: %, Version: %.',
            v_bad_element, NEW.id, NEW.form_version_id;
    END IF;

    -- [ADJ-1] If field is scored, each choice must have a numeric "score" key
    IF NEW.is_scored = TRUE THEN
        SELECT elem INTO v_bad_element
        FROM jsonb_array_elements(NEW.choice_options) elem
        WHERE elem->>'score' IS NULL
           OR jsonb_typeof(elem->'score') != 'number'
        LIMIT 1;

        IF v_bad_element IS NOT NULL THEN
            RAISE EXCEPTION
                '[ADJ-1] Field % is marked is_scored=TRUE. '
                'Every choice_options element must have a numeric "score" key. '
                'Offending element: %. '
                'Missing scores cause silent NULL returns in computed scoring. '
                'Version: %.',
                NEW.id, v_bad_element, NEW.form_version_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- Trigger already exists from Patch F01 — function replacement is sufficient.
-- The trigger trg_form_field_choice_options_compatibility will pick up the
-- updated function automatically on next execution.

COMMENT ON FUNCTION enforce_choice_options_field_type_compatibility() IS
    '[FIX-F6 + ADJ-1] Validates: '
    '1. Field type supports choice_options (single_choice, multi_choice, scale_likert). '
    '2. choice_options is a valid JSON array. '
    '3. Each element has "code" and "label". '
    '4. [ADJ-1] If is_scored=TRUE, each element must have a numeric "score" key. '
    'Prevents silent NULL scoring and UI-layer rendering corruption.';


-- =============================================================================
-- [ADJ-2] Global template mutability — confirmed correct, no change
-- =============================================================================
-- Confirmed: the existing ft_institute_update policy:
--   USING (institute_id = current_institute_id() AND ...)
-- correctly excludes global templates because institute_id IS NULL never
-- equals current_institute_id() (which is always a non-null UUID).
-- Institute users cannot accidentally modify global templates.
-- Platform admin bypass (ft_platform_admin FOR ALL) is the only path to
-- modifying global templates — correct and intentional.
-- =============================================================================

COMMENT ON TABLE form_templates IS
    'Stable identity of a form instrument. '
    'institute_id=NULL = platform-global template (CARS-2, Vineland-3, ADOS). '
    '[ADJ-2] Global templates are immutable by institute users. '
    'RLS ft_institute_update USING(institute_id = current_institute_id()) '
    'cannot match NULL — global templates excluded structurally. '
    'Only platform_admin may modify global templates.';


-- =============================================================================
-- PATCH F02 SUMMARY
-- =============================================================================
--
--  Fix/Adj  | What Changed
-- ──────────┼─────────────────────────────────────────────────────────────────
--  FIX-F8   | chk_no_self_parent CHECK on form_versions (Layer 1)
--            | enforce_version_tree_no_cycles() function (Layer 2)
--            | trg_form_version_no_cycles trigger
--            | Cycle creation in version tree is now structurally impossible
--
--  FIX-F9   | uq_fv_single_open_active_version partial unique index
--            | enforce_version_effective_no_overlap() function
--            | trg_form_version_effective_no_overlap trigger
--            | Ambiguous clinical form resolution on any date: prevented
--
--  FIX-F10  | fv_institute_delete  — draft versions only
--            | ff_institute_delete  — fields of draft versions only
--            | fvr_institute_delete — validation rules of draft versions only
--            | clr_institute_delete — conditional rules of draft versions only
--            | Published/archived records: permanently undeletable by institutes
--
--  ADJ-1    | enforce_choice_options_field_type_compatibility() REPLACED
--            | Added: is_scored=TRUE → each choice must have numeric "score" key
--            | Prevents silent NULL returns in computed scoring
--
--  ADJ-2    | No schema change — global template mutability confirmed correct
--            | Documented on form_templates table comment
--
-- =============================================================================
-- FORM DEFINITION LAYER — FINAL STATUS
-- =============================================================================
--
--  Area                                 | Enforcement          | Status
-- ──────────────────────────────────────┼──────────────────────┼────────────
--  Tenant isolation                     | Composite FK         | Structural
--  Cross-institute version branching    | Trigger              | Structural
--  Version metadata immutability        | Trigger              | Structural
--  Field/rule/logic immutability        | Trigger              | Structural
--  Version tree topology                | Composite FK         | Structural
--  Version tree cycles                  | CHECK + Trigger      | Structural
--  Effective date ambiguity             | Partial index + Trig | Structural
--  value_column domain                  | CHECK                | Structural
--  choice_options type compatibility    | Trigger              | Structural
--  choice_options structure validity    | Trigger              | Structural
--  Scored field choice score presence   | Trigger              | Structural
--  Draft DELETE allowed                 | RLS                  | Policy
--  Published/archived DELETE blocked    | RLS + Trigger        | Policy + Structural
--  Draft UPDATE/INSERT allowed          | RLS                  | Policy
--  Global template immutability         | RLS (NULL != UUID)   | Structural
--  Institute boundary throughout        | Composite FK chain   | Structural
--
-- Definition layer is production-frozen.
-- Response layer (phase2_form_responses.sql) may now be written.
-- =============================================================================