-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 2 — DYNAMIC FORM ENGINE: DEFINITION LAYER
-- =============================================================================
-- Apply after: phase1_foundation.sql + phase1_patch01.sql + phase1_patch02.sql
-- =============================================================================
--
-- LOCKED DECISIONS GOVERNING THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [D1]  Response storage: fully normalized field rows (Option B). No JSONB blobs.
-- [D2]  Field values: multi-column typed storage + exactly-one CHECK constraint.
-- [D3]  Computed score stored on form_responses header, not recalculated.
-- [D4]  Versioning: branchable tree via parent_version_id. Linear is insufficient.
-- [D5]  Context attachment: many-to-many via form_template_context_map.
-- [D6]  Published versions are IMMUTABLE. Trigger enforces. No exceptions.
-- [D7]  response_field_values references (field_id, form_version_id) composite FK.
--       Field meaning is frozen at capture time.
-- [D8]  response_mode column on form_responses: 'clinical','pilot','research_draft'.
--       Same table — no separate staging schema.
-- [D9]  Research scope: institute-scoped in OLTP. No platform researcher RLS bypass.
--       Cross-institute analytics = warehouse layer only (not this schema).
-- [D10] form_fields cannot be edited once their version is published.
--       Enforced by trigger. Prevents retroactive meaning drift on scored instruments.
--
-- DEFINITION LAYER (this file):
--   form_template_contexts, form_templates, form_versions,
--   form_fields, field_validation_rules, conditional_logic
--
-- RESPONSE LAYER (phase2_form_responses.sql):
--   form_responses, response_field_values
--   (Built after definition layer — field typing drives response schema)
-- =============================================================================


-- =============================================================================
-- SECTION 1 — FORM TEMPLATE CONTEXTS (lookup)  [D5]
-- =============================================================================
-- Many-to-many: a form can be simultaneously an evaluation instrument,
-- a research instrument, and a session documentation template.
-- Context is never exclusive.
-- =============================================================================

CREATE TABLE form_template_contexts (
    id              UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    code            TEXT            NOT NULL UNIQUE,
        -- 'intake'          patient registration + history collection
        -- 'evaluation'      standardised + custom assessment instruments
        -- 'session'         therapy session documentation
        -- 'milestone'       milestone checkpoint forms
        -- 'research'        research data collection (flagged separately from clinical)
        -- 'discharge'       discharge summary templates
        -- 'insurance'       insurance + third-party payer documentation
    name            TEXT            NOT NULL,
    description     TEXT,
    is_clinical     BOOLEAN         NOT NULL DEFAULT TRUE,  -- affects RLS and billing logic
    sort_order      INTEGER         NOT NULL DEFAULT 0,
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by      UUID            REFERENCES users(id)
);

INSERT INTO form_template_contexts (code, name, description, is_clinical, sort_order) VALUES
    ('intake',      'Intake',               'Patient registration and history collection',          TRUE,  1),
    ('evaluation',  'Evaluation',           'Standardised and custom assessment instruments',       TRUE,  2),
    ('session',     'Session Documentation','Therapy session notes and progress documentation',     TRUE,  3),
    ('milestone',   'Milestone',            'Milestone checkpoint and goal review forms',           TRUE,  4),
    ('research',    'Research',             'Research data collection — not part of clinical chart',FALSE, 5),
    ('discharge',   'Discharge',            'Discharge summary and outcome documentation',          TRUE,  6),
    ('insurance',   'Insurance',            'Insurance and third-party payer documentation',        FALSE, 7);

CREATE INDEX idx_ftc_active ON form_template_contexts(is_active);


-- =============================================================================
-- SECTION 2 — FORM TEMPLATES
-- =============================================================================
-- A template is the stable identity of a form instrument.
-- Versions branch off templates. Responses are attached to versions, not templates.
-- institute_id is nullable: NULL = global/platform form (e.g. standard CARS).
-- =============================================================================

CREATE TABLE form_templates (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            REFERENCES institutes(id),  -- NULL = platform-global
    code                TEXT            NOT NULL,
        -- 'CARS_2', 'VINELAND_3', 'INTAKE_PAEDIATRIC', 'SESSION_OT_ADULT'
    name                TEXT            NOT NULL,
    description         TEXT,
    is_global           BOOLEAN         NOT NULL
                            GENERATED ALWAYS AS (institute_id IS NULL) STORED,
    is_scored           BOOLEAN         NOT NULL DEFAULT FALSE,  -- does it produce a numeric score?
    scoring_notes       TEXT,           -- interpretation guidelines stored as text
    source_reference    TEXT,           -- citation for standardised instruments
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Code unique within institute (NULL institute = global, unique globally)
    CONSTRAINT uq_template_code_per_institute UNIQUE (institute_id, code)
);

COMMENT ON TABLE form_templates IS
    'Stable identity of a form instrument. '
    'institute_id=NULL means platform-global (e.g. standard CARS-2). '
    'Institutes may create their own variants by creating a new template '
    'branched from a global version. [D4]';

COMMENT ON COLUMN form_templates.is_global IS
    'Generated column. True when institute_id is NULL. '
    'Global forms are owned by the platform and cannot be edited by institutes. '
    'Institute-specific variants are created by branching (parent_version_id).';

CREATE INDEX idx_ft_institute   ON form_templates(institute_id);
CREATE INDEX idx_ft_global      ON form_templates(is_global) WHERE is_global = TRUE;
CREATE INDEX idx_ft_active      ON form_templates(institute_id, is_active) WHERE is_active = TRUE;

-- Many-to-many: template ↔ context  [D5]
CREATE TABLE form_template_context_map (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    form_template_id    UUID            NOT NULL REFERENCES form_templates(id) ON DELETE CASCADE,
    context_id          UUID            NOT NULL REFERENCES form_template_contexts(id),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),

    CONSTRAINT uq_template_context UNIQUE (form_template_id, context_id)
);

CREATE INDEX idx_ftcm_template  ON form_template_context_map(form_template_id);
CREATE INDEX idx_ftcm_context   ON form_template_context_map(context_id);

-- Which departments are authorised to use which templates
CREATE TABLE form_template_department_map (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    form_template_id    UUID            NOT NULL REFERENCES form_templates(id),
    department_id       UUID            NOT NULL REFERENCES departments(id),
    is_required         BOOLEAN         NOT NULL DEFAULT FALSE, -- mandatory for this dept workflow
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),

    CONSTRAINT uq_template_dept UNIQUE (form_template_id, department_id)
);

CREATE INDEX idx_ftdm_template      ON form_template_department_map(form_template_id);
CREATE INDEX idx_ftdm_department    ON form_template_department_map(department_id);
CREATE INDEX idx_ftdm_institute     ON form_template_department_map(institute_id);


-- =============================================================================
-- SECTION 3 — FORM VERSIONS (branchable tree)  [D4] [D6]
-- =============================================================================
-- parent_version_id enables branching:
--   Global CARS-2 v1 → Institute A variant (branch) → Institute A v2
--                    ↘ Research variant (branch)
--
-- Published versions are IMMUTABLE. Enforced by trigger below.
-- Fields, validation rules, and conditional logic all reference version, not template.
-- =============================================================================

CREATE TABLE form_versions (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    form_template_id    UUID            NOT NULL REFERENCES form_templates(id),
    institute_id        UUID            REFERENCES institutes(id),  -- NULL = global version
    parent_version_id   UUID            REFERENCES form_versions(id),  -- NULL = root version
    version_number      TEXT            NOT NULL,   -- semantic: '1.0.0', '1.1.0', '2.0.0-research'
    version_label       TEXT,           -- human label: 'Institute A Paediatric Variant'
    change_summary      TEXT,           -- what changed from parent
    status              TEXT            NOT NULL DEFAULT 'draft',
        -- 'draft' → 'review' → 'published' → 'archived'
        -- Once published: fields immutable. [D6]
    is_published        BOOLEAN         NOT NULL
                            GENERATED ALWAYS AS (status = 'published') STORED,
    effective_from      DATE,           -- date from which this version is used clinically
    effective_to        DATE,           -- NULL = currently active
    published_at        TIMESTAMPTZ,
    published_by        UUID            REFERENCES users(id),
    archived_at         TIMESTAMPTZ,
    archived_by         UUID            REFERENCES users(id),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Enable composite FK target from form_fields  [D7]
    CONSTRAINT uq_version_id_template UNIQUE (id, form_template_id),

    CONSTRAINT uq_version_number_per_template
        UNIQUE (form_template_id, institute_id, version_number),

    CONSTRAINT chk_effective_dates
        CHECK (effective_to IS NULL OR effective_to > effective_from)
);

COMMENT ON TABLE form_versions IS
    '[D4] Branchable version tree via parent_version_id. '
    '[D6] Published versions are immutable — trigger blocks field edits. '
    'status flow: draft → review → published → archived. '
    'is_published is a generated column (status=published). '
    'effective_from/to track which version was active on any given clinical date.';

CREATE INDEX idx_fv_template        ON form_versions(form_template_id);
CREATE INDEX idx_fv_institute       ON form_versions(institute_id);
CREATE INDEX idx_fv_parent          ON form_versions(parent_version_id);
CREATE INDEX idx_fv_status          ON form_versions(status);
CREATE INDEX idx_fv_published       ON form_versions(form_template_id, is_published)
    WHERE is_published = TRUE;
CREATE INDEX idx_fv_effective       ON form_versions(effective_from, effective_to)
    WHERE status = 'published';

-- Immutability enforcement: block status downgrade from published  [D6]
CREATE OR REPLACE FUNCTION enforce_version_publish_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Once published, status cannot change to anything other than 'archived'
    IF OLD.status = 'published' AND NEW.status NOT IN ('published', 'archived') THEN
        RAISE EXCEPTION
            'form_version % is published. Status cannot be changed to %. '
            'Published versions are immutable. Create a new version to make changes.',
            OLD.id, NEW.status;
    END IF;

    -- Block metadata edits on published versions (except archiving fields)
    IF OLD.status = 'published' AND NEW.status = 'published' THEN
        IF NEW.version_number    != OLD.version_number    OR
           NEW.form_template_id  != OLD.form_template_id  OR
           NEW.parent_version_id IS DISTINCT FROM OLD.parent_version_id OR
           NEW.effective_from    IS DISTINCT FROM OLD.effective_from
        THEN
            RAISE EXCEPTION
                'form_version % is published and immutable. '
                'Core fields (version_number, template, parent, effective_from) cannot be changed.',
                OLD.id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_form_version_immutability
    BEFORE UPDATE ON form_versions
    FOR EACH ROW
    EXECUTE FUNCTION enforce_version_publish_immutability();


-- =============================================================================
-- SECTION 4 — FORM FIELDS  [D6] [D7] [D10]
-- =============================================================================
-- Fields belong to a version, not a template directly.
-- Field order within a version is explicit (sort_order).
-- Fields support grouping (section/group via parent_field_id).
-- Published version → fields immutable. Trigger enforces.  [D10]
-- UNIQUE (id, form_version_id) enables composite FK from response_field_values. [D7]
-- =============================================================================

-- Field type lookup — extensible, no ENUM
CREATE TABLE form_field_types (
    id              UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    code            TEXT            NOT NULL UNIQUE,
        -- 'text_short', 'text_long', 'number', 'decimal', 'boolean',
        -- 'single_choice', 'multi_choice', 'scale_likert', 'scale_numeric',
        -- 'date', 'datetime', 'file_upload', 'section_header', 'group',
        -- 'score_computed', 'signature', 'table_matrix'
    name            TEXT            NOT NULL,
    stores_value    BOOLEAN         NOT NULL DEFAULT TRUE,  -- FALSE for section_header
    value_column    TEXT,
        -- which column in response_field_values this type writes to:
        -- 'value_text','value_numeric','value_boolean','value_date','value_json'
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by      UUID            REFERENCES users(id)
);

INSERT INTO form_field_types (code, name, stores_value, value_column) VALUES
    ('text_short',      'Short Text',           TRUE,  'value_text'),
    ('text_long',       'Long Text',             TRUE,  'value_text'),
    ('number',          'Integer Number',        TRUE,  'value_numeric'),
    ('decimal',         'Decimal Number',        TRUE,  'value_numeric'),
    ('boolean',         'Yes / No',              TRUE,  'value_boolean'),
    ('single_choice',   'Single Choice',         TRUE,  'value_text'),    -- stores choice code
    ('multi_choice',    'Multiple Choice',       TRUE,  'value_json'),    -- stores array of codes
    ('scale_likert',    'Likert Scale',          TRUE,  'value_numeric'),
    ('scale_numeric',   'Numeric Scale',         TRUE,  'value_numeric'),
    ('date',            'Date',                  TRUE,  'value_date'),
    ('datetime',        'Date and Time',         TRUE,  'value_text'),    -- ISO8601 stored as text
    ('file_upload',     'File Upload',           TRUE,  'value_text'),    -- stores object storage ref
    ('section_header',  'Section Header',        FALSE, NULL),            -- layout only
    ('group',           'Field Group',           FALSE, NULL),            -- layout grouping
    ('score_computed',  'Computed Score',        TRUE,  'value_numeric'), -- system-calculated
    ('signature',       'Signature',             TRUE,  'value_text'),    -- stores sig ref
    ('table_matrix',    'Table / Matrix',        TRUE,  'value_json');    -- stores row/col answers

-- ---------------------------------------------------------------------------

CREATE TABLE form_fields (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    form_version_id     UUID            NOT NULL REFERENCES form_versions(id),
    form_template_id    UUID            NOT NULL REFERENCES form_templates(id),
    parent_field_id     UUID            REFERENCES form_fields(id), -- for grouped/nested fields
    field_type_id       UUID            NOT NULL REFERENCES form_field_types(id),
    code                TEXT            NOT NULL,   -- stable field identifier within template
        -- used for scoring lookups, research column naming, DPDP export labels
    label               TEXT            NOT NULL,   -- display label shown to clinician
    label_translations  JSONB,          -- {'hi': '...', 'ta': '...'} for multilingual support
    placeholder         TEXT,
    help_text           TEXT,
    is_required         BOOLEAN         NOT NULL DEFAULT FALSE,
    is_scored           BOOLEAN         NOT NULL DEFAULT FALSE,
    score_weight        NUMERIC(8,4),   -- for weighted composite scoring
    min_value           NUMERIC,        -- for numeric/scale fields
    max_value           NUMERIC,
    choice_options      JSONB,
        -- for single_choice/multi_choice:
        -- [{"code": "never", "label": "Never", "score": 0}, ...]
    sort_order          INTEGER         NOT NULL DEFAULT 0,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- [D7] Composite unique: enables FK from response_field_values(field_id, form_version_id)
    CONSTRAINT uq_field_id_version UNIQUE (id, form_version_id),

    -- Field code unique within a version
    CONSTRAINT uq_field_code_per_version UNIQUE (form_version_id, code),

    -- template consistency: field's version must belong to field's template
    CONSTRAINT fk_field_version_template
        FOREIGN KEY (form_version_id, form_template_id)
        REFERENCES form_versions(id, form_template_id)
        DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE form_fields IS
    '[D10] Immutable once parent form_version is published. Trigger enforces. '
    '[D7] UNIQUE (id, form_version_id) enables composite FK from response layer. '
    'field code is stable within a template — used for scoring, export, analytics. '
    'choice_options JSONB intentional: structure varies by field type, not queried independently.';

COMMENT ON COLUMN form_fields.code IS
    'Stable field identifier within this template. Used for: '
    'scoring formula references, research column naming, DPDP data subject export labels. '
    'Must be unique per version. Should be consistent across versions for same logical field.';

CREATE INDEX idx_ff_version         ON form_fields(form_version_id);
CREATE INDEX idx_ff_template        ON form_fields(form_template_id);
CREATE INDEX idx_ff_parent          ON form_fields(parent_field_id);
CREATE INDEX idx_ff_type            ON form_fields(field_type_id);
CREATE INDEX idx_ff_code            ON form_fields(form_version_id, code);
CREATE INDEX idx_ff_sort            ON form_fields(form_version_id, sort_order);
CREATE INDEX idx_ff_scored          ON form_fields(form_version_id, is_scored)
    WHERE is_scored = TRUE;

-- [D10] Published version field immutability trigger
CREATE OR REPLACE FUNCTION enforce_field_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_version_status TEXT;
BEGIN
    SELECT status INTO v_version_status
    FROM form_versions
    WHERE id = COALESCE(OLD.form_version_id, NEW.form_version_id);

    IF v_version_status = 'published' THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION
                'Cannot delete field % — form_version % is published and immutable. '
                'Create a new version to remove or modify fields.',
                OLD.id, OLD.form_version_id;
        END IF;
        IF TG_OP = 'UPDATE' THEN
            RAISE EXCEPTION
                'Cannot modify field % — form_version % is published and immutable. '
                'Field label, type, scoring, options, and order are frozen at publish. '
                'Create a new version to make changes.',
                OLD.id, OLD.form_version_id;
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_form_field_immutability
    BEFORE UPDATE OR DELETE ON form_fields
    FOR EACH ROW
    EXECUTE FUNCTION enforce_field_immutability();

COMMENT ON TRIGGER trg_form_field_immutability ON form_fields IS
    '[D10] Blocks UPDATE and DELETE on fields belonging to published versions. '
    'Prevents retroactive meaning drift on scored instruments (CARS, Vineland, ADOS). '
    'Regulatory requirement: historical response meaning must be traceable.';


-- =============================================================================
-- SECTION 5 — FIELD VALIDATION RULES
-- =============================================================================
-- Validation rules are attached to fields and evaluated at response capture time.
-- They are also immutable once the version is published (inherit from field).
-- Validation logic is declarative — evaluated by the application layer.
-- =============================================================================

-- Validation rule types lookup
CREATE TABLE validation_rule_types (
    id              UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    code            TEXT            NOT NULL UNIQUE,
        -- 'required', 'min_value', 'max_value', 'min_length', 'max_length',
        -- 'regex_pattern', 'date_range', 'must_be_integer',
        -- 'min_selections', 'max_selections',  -- for multi_choice
        -- 'sum_equals',  -- for grouped score fields
        -- 'custom_message'
    name            TEXT            NOT NULL,
    applies_to      JSONB,          -- array of field_type codes this rule is valid for
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

INSERT INTO validation_rule_types (code, name, applies_to) VALUES
    ('required',        'Required',             '["*"]'),
    ('min_value',       'Minimum Value',        '["number","decimal","scale_likert","scale_numeric"]'),
    ('max_value',       'Maximum Value',        '["number","decimal","scale_likert","scale_numeric"]'),
    ('min_length',      'Minimum Length',       '["text_short","text_long"]'),
    ('max_length',      'Maximum Length',       '["text_short","text_long"]'),
    ('regex_pattern',   'Regex Pattern',        '["text_short","text_long"]'),
    ('date_range',      'Date Range',           '["date","datetime"]'),
    ('must_be_integer', 'Must Be Integer',      '["number","scale_likert","scale_numeric"]'),
    ('min_selections',  'Minimum Selections',   '["multi_choice"]'),
    ('max_selections',  'Maximum Selections',   '["multi_choice"]'),
    ('sum_equals',      'Sum Equals Target',    '["number","decimal","scale_numeric"]'),
    ('custom_message',  'Custom Error Message', '["*"]');

-- ---------------------------------------------------------------------------

CREATE TABLE field_validation_rules (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    field_id            UUID            NOT NULL REFERENCES form_fields(id) ON DELETE CASCADE,
    form_version_id     UUID            NOT NULL REFERENCES form_versions(id),
    rule_type_id        UUID            NOT NULL REFERENCES validation_rule_types(id),
    rule_value          TEXT,           -- '0', '100', '^[A-Z]+$', '2024-01-01'
    error_message       TEXT            NOT NULL,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),

    CONSTRAINT uq_field_rule_type UNIQUE (field_id, rule_type_id),

    -- Ensure validation rule's version matches its field's version
    CONSTRAINT fk_validation_field_version
        FOREIGN KEY (field_id, form_version_id)
        REFERENCES form_fields(id, form_version_id)
        DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX idx_fvr_field          ON field_validation_rules(field_id);
CREATE INDEX idx_fvr_version        ON field_validation_rules(form_version_id);

-- Inherit immutability from published version
CREATE TRIGGER trg_validation_rule_immutability
    BEFORE UPDATE OR DELETE ON field_validation_rules
    FOR EACH ROW
    EXECUTE FUNCTION enforce_field_immutability();
    -- Reuses same function — checks form_version status via form_version_id


-- =============================================================================
-- SECTION 6 — CONDITIONAL LOGIC
-- =============================================================================
-- Declarative show/hide and enable/disable logic between fields.
-- Stored as rules; evaluated by application layer at render time.
-- Immutable once version is published.
-- =============================================================================

CREATE TABLE conditional_logic_actions (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    code            TEXT        NOT NULL UNIQUE,
        -- 'show', 'hide', 'require', 'disable', 'set_value', 'jump_to_section'
    name            TEXT        NOT NULL,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO conditional_logic_actions (code, name) VALUES
    ('show',            'Show Field'),
    ('hide',            'Hide Field'),
    ('require',         'Make Required'),
    ('disable',         'Disable Field'),
    ('set_value',       'Set Field Value'),
    ('jump_to_section', 'Jump to Section');

CREATE TABLE conditional_logic_operators (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    code            TEXT        NOT NULL UNIQUE,
        -- 'equals', 'not_equals', 'greater_than', 'less_than',
        -- 'contains', 'is_empty', 'is_not_empty', 'in_list'
    name            TEXT        NOT NULL,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO conditional_logic_operators (code, name) VALUES
    ('equals',          'Equals'),
    ('not_equals',      'Not Equals'),
    ('greater_than',    'Greater Than'),
    ('less_than',       'Less Than'),
    ('greater_eq',      'Greater Than or Equal'),
    ('less_eq',         'Less Than or Equal'),
    ('contains',        'Contains'),
    ('is_empty',        'Is Empty'),
    ('is_not_empty',    'Is Not Empty'),
    ('in_list',         'Is One Of');

-- ---------------------------------------------------------------------------

CREATE TABLE conditional_logic_rules (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    form_version_id     UUID            NOT NULL REFERENCES form_versions(id),
    -- Source: the field whose value is evaluated
    source_field_id     UUID            NOT NULL REFERENCES form_fields(id),
    operator_id         UUID            NOT NULL REFERENCES conditional_logic_operators(id),
    condition_value     TEXT,           -- the value to compare against
    -- Target: the field that is acted upon when condition is true
    target_field_id     UUID            NOT NULL REFERENCES form_fields(id),
    action_id           UUID            NOT NULL REFERENCES conditional_logic_actions(id),
    action_value        TEXT,           -- for set_value action
    -- Grouping: multiple rules on the same target with same group are AND-ed
    rule_group          INTEGER         NOT NULL DEFAULT 1,
    sort_order          INTEGER         NOT NULL DEFAULT 0,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),

    -- Source and target fields must belong to same version
    CONSTRAINT fk_clr_source_version
        FOREIGN KEY (source_field_id, form_version_id)
        REFERENCES form_fields(id, form_version_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_clr_target_version
        FOREIGN KEY (target_field_id, form_version_id)
        REFERENCES form_fields(id, form_version_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- A field cannot be its own condition source and target in same rule
    CONSTRAINT chk_clr_no_self_reference
        CHECK (source_field_id != target_field_id)
);

COMMENT ON TABLE conditional_logic_rules IS
    'Declarative field show/hide/require logic. Evaluated by application layer. '
    'rule_group allows AND grouping: multiple rows with same (target, group) are AND conditions. '
    'Different rule_group values for same target are OR conditions. '
    'Source and target must belong to same form_version — enforced by composite FKs.';

CREATE INDEX idx_clr_version        ON conditional_logic_rules(form_version_id);
CREATE INDEX idx_clr_source         ON conditional_logic_rules(source_field_id);
CREATE INDEX idx_clr_target         ON conditional_logic_rules(target_field_id);

-- Inherit immutability from published version
CREATE OR REPLACE FUNCTION enforce_conditional_logic_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_version_status TEXT;
BEGIN
    SELECT status INTO v_version_status
    FROM form_versions
    WHERE id = COALESCE(OLD.form_version_id, NEW.form_version_id);

    IF v_version_status = 'published' THEN
        RAISE EXCEPTION
            'Cannot modify conditional logic rule % — form_version % is published and immutable.',
            COALESCE(OLD.id, NEW.id), COALESCE(OLD.form_version_id, NEW.form_version_id);
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_conditional_logic_immutability
    BEFORE UPDATE OR DELETE ON conditional_logic_rules
    FOR EACH ROW
    EXECUTE FUNCTION enforce_conditional_logic_immutability();


-- =============================================================================
-- SECTION 7 — RLS ON DEFINITION LAYER  [D9]
-- =============================================================================
-- Research scope: institute-scoped in OLTP. No platform researcher bypass.
-- Form templates: global templates visible to all institutes.
--   Institute-specific templates: visible within their institute only.
-- Form versions/fields: follow template visibility.
-- =============================================================================

-- form_templates
ALTER TABLE form_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE form_templates FORCE ROW LEVEL SECURITY;

CREATE POLICY ft_platform_admin ON form_templates
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY ft_global_read ON form_templates
    FOR SELECT
    USING (is_global = TRUE);   -- global templates readable by all authenticated users

CREATE POLICY ft_institute_read ON form_templates
    FOR SELECT
    USING (
        is_global = FALSE
        AND institute_id = current_institute_id()
    );

CREATE POLICY ft_institute_write ON form_templates
    FOR INSERT WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );

CREATE POLICY ft_institute_update ON form_templates
    FOR UPDATE USING (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );

-- form_versions
ALTER TABLE form_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE form_versions FORCE ROW LEVEL SECURITY;

CREATE POLICY fv_platform_admin ON form_versions
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY fv_read ON form_versions
    FOR SELECT
    USING (
        institute_id IS NULL   -- global version
        OR institute_id = current_institute_id()
    );

CREATE POLICY fv_write ON form_versions
    FOR INSERT WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_FORMS')
    );

-- form_fields — same visibility as their version
ALTER TABLE form_fields ENABLE ROW LEVEL SECURITY;
ALTER TABLE form_fields FORCE ROW LEVEL SECURITY;

CREATE POLICY ff_platform_admin ON form_fields
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY ff_read ON form_fields
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = form_fields.form_version_id
              AND (fv.institute_id IS NULL OR fv.institute_id = current_institute_id())
        )
    );

-- field_validation_rules and conditional_logic_rules inherit same pattern
ALTER TABLE field_validation_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE field_validation_rules FORCE ROW LEVEL SECURITY;

CREATE POLICY fvr_platform_admin ON field_validation_rules
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY fvr_read ON field_validation_rules
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = field_validation_rules.form_version_id
              AND (fv.institute_id IS NULL OR fv.institute_id = current_institute_id())
        )
    );

ALTER TABLE conditional_logic_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE conditional_logic_rules FORCE ROW LEVEL SECURITY;

CREATE POLICY clr_platform_admin ON conditional_logic_rules
    FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY clr_read ON conditional_logic_rules
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM form_versions fv
            WHERE fv.id = conditional_logic_rules.form_version_id
              AND (fv.institute_id IS NULL OR fv.institute_id = current_institute_id())
        )
    );


-- =============================================================================
-- SECTION 8 — PERMISSIONS SEED FOR FORM ENGINE
-- =============================================================================

INSERT INTO permissions (code, name, module, description) VALUES
    ('CAN_MANAGE_FORMS',        'Manage Form Templates',    'clinical',
        'Create, edit, and publish form templates and versions'),
    ('CAN_VIEW_FORM_TEMPLATES', 'View Form Templates',      'clinical',
        'View form definitions and version history'),
    ('CAN_COLLECT_RESPONSES',   'Collect Form Responses',   'clinical',
        'Fill in and submit form responses for patients'),
    ('CAN_VIEW_RESPONSES',      'View Form Responses',      'clinical',
        'View submitted form responses for assigned patients'),
    ('CAN_EXPORT_FORM_DATA',    'Export Form Data',         'research',
        'Export anonymised form response data for research purposes')
ON CONFLICT (code) DO NOTHING;


-- =============================================================================
-- DEFINITION LAYER COMPLETE — INVENTORY
-- =============================================================================
--
-- Lookup tables  : form_template_contexts, form_field_types,
--                  validation_rule_types, conditional_logic_actions,
--                  conditional_logic_operators
--
-- Core definition: form_templates, form_template_context_map,
--                  form_template_department_map,
--                  form_versions, form_fields,
--                  field_validation_rules, conditional_logic_rules
--
-- Immutability   : trg_form_version_immutability (version metadata)
--                  trg_form_field_immutability (fields + validation rules)
--                  trg_conditional_logic_immutability (conditional rules)
--
-- RLS            : form_templates, form_versions, form_fields,
--                  field_validation_rules, conditional_logic_rules
--                  — all institute-scoped, global templates readable by all
--
-- Permissions    : CAN_MANAGE_FORMS, CAN_VIEW_FORM_TEMPLATES,
--                  CAN_COLLECT_RESPONSES, CAN_VIEW_RESPONSES,
--                  CAN_EXPORT_FORM_DATA
--
-- =============================================================================
-- RESPONSE LAYER — phase2_form_responses.sql — NEXT FILE
-- =============================================================================
-- Will cover:
--   form_responses  (header record per submission)
--   response_field_values  (one row per field per response)
--     → typed columns: value_text, value_numeric, value_boolean,
--                      value_date, value_json
--     → exactly-one CHECK constraint  [D2]
--     → computed_score on form_responses header  [D3]
--     → response_mode column: 'clinical','pilot','research_draft'  [D8]
--     → composite FK (field_id, form_version_id) → form_fields  [D7]
--   RLS anchored to patient_provider_assignments
-- =============================================================================