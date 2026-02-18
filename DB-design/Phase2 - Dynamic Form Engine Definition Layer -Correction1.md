-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 2 — FORM DEFINITION PATCH 01: STRUCTURAL CORRECTIONS
-- =============================================================================
-- Apply after: phase1_foundation.sql + patches + phase2_form_definition.sql
-- =============================================================================
--
-- CORRECTIONS IN THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [FIX-F1] enforce_version_publish_immutability() — incomplete column blocking.
--          Only blocked version_number, template, parent, effective_from.
--          Must block ALL metadata changes post-publish except archived_at/by/status.
--          Editing change_summary on a published version modifies regulatory history.
--
-- [FIX-F2] form_versions — no enforcement that a version's institute matches its
--          template's institute (or template is global). Cross-institute version
--          branching was structurally possible. Trigger added.
--
-- [FIX-F3] parent_version_id — no composite FK ensuring parent belongs to same
--          template. Could branch from unrelated template version. Corrupt tree.
--          Fixed via UNIQUE (id, form_template_id) + composite FK.
--
-- [FIX-F4] form_field_types.value_column — no domain enforcement.
--          Unconstrained text column could store invalid column names, breaking
--          response layer. CHECK constraint added.
--
-- [FIX-F5] RLS — missing UPDATE policies on form_versions, form_fields,
--          field_validation_rules, conditional_logic_rules.
--          Institutes could INSERT drafts but not edit them. Broken workflow.
--
-- [FIX-F6] choice_options JSONB on non-choice field types — no enforcement.
--          Numeric/boolean fields could store choice_options. Trigger added.
--
-- [FIX-F7] form_template_department_map — missing composite institute FKs.
--          Cross-institute template-department mapping was structurally possible.
-- =============================================================================


-- =============================================================================
-- [FIX-F1] Full metadata immutability on published versions
-- =============================================================================
-- Replace the incomplete function from phase2_form_definition.sql.
-- Once published, ONLY archived_at, archived_by, and status (→ 'archived') may change.
-- Everything else is regulatory history and must be frozen.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_version_publish_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Prevent status downgrade from published to anything except archived
    IF OLD.status = 'published' AND NEW.status NOT IN ('published', 'archived') THEN
        RAISE EXCEPTION
            '[FIX-F1] form_version % is published. '
            'Status can only transition published → archived. Attempted: %.',
            OLD.id, NEW.status;
    END IF;

    -- Once published, block ALL field changes except archiving columns
    IF OLD.status = 'published' AND NEW.status IN ('published', 'archived') THEN
        IF NEW.form_template_id      IS DISTINCT FROM OLD.form_template_id      OR
           NEW.institute_id          IS DISTINCT FROM OLD.institute_id          OR
           NEW.parent_version_id     IS DISTINCT FROM OLD.parent_version_id     OR
           NEW.version_number        IS DISTINCT FROM OLD.version_number        OR
           NEW.version_label         IS DISTINCT FROM OLD.version_label         OR
           NEW.change_summary        IS DISTINCT FROM OLD.change_summary        OR
           NEW.effective_from        IS DISTINCT FROM OLD.effective_from        OR
           NEW.effective_to          IS DISTINCT FROM OLD.effective_to          OR
           NEW.published_at          IS DISTINCT FROM OLD.published_at          OR
           NEW.published_by          IS DISTINCT FROM OLD.published_by
        THEN
            RAISE EXCEPTION
                '[FIX-F1] form_version % is published and fully immutable. '
                'All metadata is frozen including version_label, change_summary, '
                'effective dates, and published_by. '
                'Only archived_at and archived_by may be set. '
                'Create a new version to make any changes.',
                OLD.id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_version_publish_immutability() IS
    '[FIX-F1] Blocks ALL metadata changes post-publish except archived_at/by/status→archived. '
    'change_summary, version_label, effective_to, published_at/by are regulatory history — frozen. '
    'Status flow: draft → review → published → archived. No reversals.';


-- =============================================================================
-- [FIX-F2] form_versions — template-version institute consistency
-- =============================================================================
-- Allowed combinations:
--   template.institute_id IS NULL     (global)  → version.institute_id = anything
--   template.institute_id = X         (owned)   → version.institute_id = X only
-- Blocked:
--   template.institute_id = A  →  version.institute_id = B
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_version_institute_consistency()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_template_institute UUID;
BEGIN
    SELECT institute_id INTO v_template_institute
    FROM form_templates
    WHERE id = NEW.form_template_id;

    -- Global template: any institute can create a version (branching allowed)
    IF v_template_institute IS NULL THEN
        RETURN NEW;
    END IF;

    -- Institute-owned template: version must belong to same institute
    IF NEW.institute_id IS DISTINCT FROM v_template_institute THEN
        RAISE EXCEPTION
            '[FIX-F2] form_version institute mismatch. '
            'Template % belongs to institute %. '
            'Version cannot belong to institute %. '
            'Cross-institute version branching from an owned template is not permitted. '
            'To create an institute-specific variant of a global form, '
            'the template itself must be global (institute_id IS NULL).',
            NEW.form_template_id, v_template_institute, NEW.institute_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_form_version_institute_consistency
    BEFORE INSERT OR UPDATE OF form_template_id, institute_id
    ON form_versions
    FOR EACH ROW
    EXECUTE FUNCTION enforce_version_institute_consistency();

COMMENT ON TRIGGER trg_form_version_institute_consistency ON form_versions IS
    '[FIX-F2] Enforces: owned template versions stay within owner institute. '
    'Global template versions may belong to any institute (branching model). '
    'Prevents cross-institute version tree contamination.';


-- =============================================================================
-- [FIX-F3] parent_version_id — enforce same-template tree integrity
-- =============================================================================
-- parent_version_id alone only enforces the parent row exists.
-- It does NOT enforce the parent belongs to the same template.
-- Fix: add UNIQUE (id, form_template_id) + composite FK on parent.
-- =============================================================================

-- Step 1: UNIQUE (id, form_template_id) already exists from phase2_form_definition.sql:
--   CONSTRAINT uq_version_id_template UNIQUE (id, form_template_id)
-- Verify it exists, then add composite FK.

-- Step 2: Add composite FK ensuring parent belongs to same template
ALTER TABLE form_versions
    ADD CONSTRAINT fk_parent_version_same_template
    FOREIGN KEY (parent_version_id, form_template_id)
    REFERENCES form_versions(id, form_template_id)
    DEFERRABLE INITIALLY DEFERRED;

COMMENT ON CONSTRAINT fk_parent_version_same_template ON form_versions IS
    '[FIX-F3] Parent version must belong to the same template. '
    'Prevents branching from an unrelated template version. '
    'Version tree topology is guaranteed to stay within one template.';


-- =============================================================================
-- [FIX-F4] form_field_types.value_column — domain enforcement
-- =============================================================================
-- Previously unconstrained TEXT. An invalid value here breaks the response layer
-- because value_column is used to determine which typed column to write to.
-- =============================================================================

ALTER TABLE form_field_types
    ADD CONSTRAINT chk_value_column_domain
    CHECK (
        value_column IN (
            'value_text',
            'value_numeric',
            'value_boolean',
            'value_date',
            'value_json'
        )
        OR value_column IS NULL  -- NULL is valid for layout-only types (section_header, group)
    );

COMMENT ON COLUMN form_field_types.value_column IS
    '[FIX-F4] Constrained to valid response_field_values typed columns. '
    'NULL is valid for layout-only types (section_header, group) that store no value. '
    'This column is the bridge between field type definition and response storage. '
    'Any change here must be coordinated with response layer schema.';


-- =============================================================================
-- [FIX-F5] RLS — add missing UPDATE policies
-- =============================================================================
-- Institutes could INSERT draft versions and fields but could not UPDATE them.
-- This made draft editing impossible for institute users — broken workflow.
-- UPDATE is allowed only on non-published versions (immutability trigger handles
-- the published case — two layers of protection).
-- =============================================================================

-- form_versions UPDATE
CREATE POLICY fv_institute_update ON form_versions
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );

COMMENT ON POLICY fv_institute_update ON form_versions IS
    '[FIX-F5] Allows institute form managers to edit draft and review versions. '
    'Published version immutability enforced separately by trigger. '
    'Two independent layers: RLS scopes who, trigger enforces what.';

-- form_fields UPDATE
CREATE POLICY ff_institute_update ON form_fields
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = form_fields.form_version_id
              AND fv.institute_id = current_institute_id()
        )
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = form_fields.form_version_id
              AND fv.institute_id = current_institute_id()
        )
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );

-- form_fields INSERT (was missing explicit WITH CHECK)
CREATE POLICY ff_institute_insert ON form_fields
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = form_fields.form_version_id
              AND fv.institute_id = current_institute_id()
        )
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );

-- field_validation_rules UPDATE
CREATE POLICY fvr_institute_update ON field_validation_rules
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = field_validation_rules.form_version_id
              AND fv.institute_id = current_institute_id()
        )
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = field_validation_rules.form_version_id
              AND fv.institute_id = current_institute_id()
        )
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );

CREATE POLICY fvr_institute_insert ON field_validation_rules
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = field_validation_rules.form_version_id
              AND fv.institute_id = current_institute_id()
        )
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );

-- conditional_logic_rules UPDATE
CREATE POLICY clr_institute_update ON conditional_logic_rules
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = conditional_logic_rules.form_version_id
              AND fv.institute_id = current_institute_id()
        )
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = conditional_logic_rules.form_version_id
              AND fv.institute_id = current_institute_id()
        )
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );

CREATE POLICY clr_institute_insert ON conditional_logic_rules
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = conditional_logic_rules.form_version_id
              AND fv.institute_id = current_institute_id()
        )
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );


-- =============================================================================
-- [FIX-F6] choice_options — enforce field type compatibility
-- =============================================================================
-- choice_options JSONB should only be populated for field types that support
-- discrete choices. Storing choice_options on a numeric or boolean field is a
-- configuration error that will surface as silent data corruption in the UI.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_choice_options_field_type_compatibility()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_type_code TEXT;
BEGIN
    -- Only validate when choice_options is being set
    IF NEW.choice_options IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT ft.code INTO v_type_code
    FROM form_field_types ft
    WHERE ft.id = NEW.field_type_id;

    -- Only single_choice, multi_choice, and scale_likert support choice_options
    IF v_type_code NOT IN ('single_choice', 'multi_choice', 'scale_likert') THEN
        RAISE EXCEPTION
            '[FIX-F6] choice_options may not be set on field type %. '
            'Only single_choice, multi_choice, and scale_likert support discrete options. '
            'Field: %, Version: %.',
            v_type_code, NEW.id, NEW.form_version_id;
    END IF;

    -- Validate structure of choice_options: must be a JSON array
    IF jsonb_typeof(NEW.choice_options) != 'array' THEN
        RAISE EXCEPTION
            '[FIX-F6] choice_options must be a JSON array. '
            'Expected: [{"code": "...", "label": "...", "score": ...}]. '
            'Field: %, Version: %.',
            NEW.id, NEW.form_version_id;
    END IF;

    -- Each element must have at least "code" and "label"
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(NEW.choice_options) elem
        WHERE elem->>'code' IS NULL OR elem->>'label' IS NULL
    ) THEN
        RAISE EXCEPTION
            '[FIX-F6] Each choice_options element must have "code" and "label" keys. '
            'Field: %, Version: %.',
            NEW.id, NEW.form_version_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_form_field_choice_options_compatibility
    BEFORE INSERT OR UPDATE OF choice_options, field_type_id
    ON form_fields
    FOR EACH ROW
    EXECUTE FUNCTION enforce_choice_options_field_type_compatibility();

COMMENT ON TRIGGER trg_form_field_choice_options_compatibility ON form_fields IS
    '[FIX-F6] Prevents choice_options being set on incompatible field types. '
    'Also validates choice_options is a valid array with code+label on each element. '
    'Fires on INSERT and on UPDATE when choice_options or field_type_id changes.';


-- =============================================================================
-- [FIX-F7] form_template_department_map — composite institute FKs
-- =============================================================================
-- Previously: three FKs but no enforcement that department and template
-- belong to the same institute. Cross-institute mapping was structurally possible.
-- =============================================================================

-- department must belong to the same institute
ALTER TABLE form_template_department_map
    ADD CONSTRAINT fk_ftdm_department_institute
    FOREIGN KEY (department_id, institute_id)
    REFERENCES departments(id, institute_id)
    DEFERRABLE INITIALLY DEFERRED;

COMMENT ON CONSTRAINT fk_ftdm_department_institute ON form_template_department_map IS
    '[FIX-F7] Department must belong to the same institute as this mapping record. '
    'Prevents cross-institute template-department assignments.';

-- For institute-owned templates: template must belong to same institute
-- For global templates: the template.institute_id IS NULL — composite FK cannot
-- enforce this case. A trigger handles it.
CREATE OR REPLACE FUNCTION enforce_template_dept_map_consistency()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_template_institute UUID;
BEGIN
    SELECT institute_id INTO v_template_institute
    FROM form_templates
    WHERE id = NEW.form_template_id;

    -- Global templates can be mapped to any institute's department — allowed
    IF v_template_institute IS NULL THEN
        RETURN NEW;
    END IF;

    -- Owned template: must match the mapping's institute
    IF v_template_institute != NEW.institute_id THEN
        RAISE EXCEPTION
            '[FIX-F7] form_template % is owned by institute % '
            'and cannot be mapped to a department in institute %.',
            NEW.form_template_id, v_template_institute, NEW.institute_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_template_dept_map_consistency
    BEFORE INSERT OR UPDATE OF form_template_id, institute_id
    ON form_template_department_map
    FOR EACH ROW
    EXECUTE FUNCTION enforce_template_dept_map_consistency();

COMMENT ON TRIGGER trg_template_dept_map_consistency ON form_template_department_map IS
    '[FIX-F7] Owned templates can only be mapped within their own institute. '
    'Global templates (institute_id IS NULL) may be mapped to any institute department.';


-- =============================================================================
-- PATCH F01 SUMMARY
-- =============================================================================
--
--  Fix    | What Changed
-- ────────┼──────────────────────────────────────────────────────────────────
--  FIX-F1 | enforce_version_publish_immutability() REPLACED
--          | Now blocks ALL metadata changes post-publish
--          | (version_label, change_summary, effective_to, published_at/by)
--          | Only archived_at, archived_by, and status→archived permitted
--
--  FIX-F2 | enforce_version_institute_consistency() ADDED
--          | trg_form_version_institute_consistency on form_versions
--          | Owned template → version must match institute
--          | Global template → any institute may create versions
--
--  FIX-F3 | fk_parent_version_same_template ADDED on form_versions
--          | FOREIGN KEY (parent_version_id, form_template_id)
--          | → form_versions(id, form_template_id)
--          | Version tree guaranteed to stay within one template
--
--  FIX-F4 | chk_value_column_domain CHECK ADDED on form_field_types
--          | value_column constrained to 5 valid typed column names + NULL
--          | Prevents invalid column references breaking response layer
--
--  FIX-F5 | UPDATE + INSERT policies ADDED for:
--          | form_versions, form_fields, field_validation_rules,
--          | conditional_logic_rules
--          | Draft editing now functional for institute form managers
--
--  FIX-F6 | enforce_choice_options_field_type_compatibility() ADDED
--          | trg_form_field_choice_options_compatibility on form_fields
--          | Validates type compatibility + JSON array structure + code/label presence
--
--  FIX-F7 | fk_ftdm_department_institute ADDED on form_template_department_map
--          | enforce_template_dept_map_consistency() + trigger ADDED
--          | Composite FK + trigger enforce cross-institute mapping prevention
--
-- =============================================================================
-- FORM DEFINITION LAYER STATUS AFTER PATCH F01
-- =============================================================================
--
--  Area                              | Status
-- ───────────────────────────────────┼────────────────────────────────────────
--  Version tree integrity            | Parent FK same-template enforced
--  Cross-institute version branching | Structurally prevented (owned templates)
--  Version metadata immutability     | Full post-publish freeze
--  Field immutability                | Trigger enforced
--  Conditional logic immutability    | Trigger enforced
--  value_column domain               | CHECK constraint enforced
--  choice_options compatibility      | Trigger enforced + structure validated
--  Template-dept mapping integrity   | Composite FK + trigger
--  RLS completeness                  | SELECT + INSERT + UPDATE covered
--  Draft editing workflow            | Functional
--  Institute boundary                | Structurally enforced throughout
--
-- Response layer (phase2_form_responses.sql) may now be written.
-- =============================================================================