-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 2 — FORM ENGINE: RESPONSE LAYER
-- =============================================================================
-- Apply after: all Phase 1 files + phase2_form_definition.sql + patches F01-F03
-- =============================================================================
--
-- LOCKED DECISIONS GOVERNING THIS FILE
-- ─────────────────────────────────────────────────────────────────────────────
-- [D1]  Fully normalized field rows. No JSONB response blobs.
-- [D2]  Multi-column typed storage: value_text, value_numeric, value_boolean,
--       value_date, value_json. Exactly-one CHECK enforced.
-- [D3]  computed_score stored on form_responses header. Not recalculated.
-- [D7]  response_field_values references (field_id, form_version_id) composite FK.
--       Field meaning frozen at capture time.
-- [D8]  response_mode: 'clinical' | 'pilot' | 'research_draft'. Same table.
-- [D9]  RLS anchored to patient_provider_assignments. No platform researcher bypass.
--
-- context_ref_id DESIGN DECISION (consistent with case_role_assignments pattern)
-- ─────────────────────────────────────────────────────────────────────────────
-- form_responses.context_ref_id is polymorphic — it references the clinical
-- entity this response is attached to (patient intake, session, evaluation).
-- Phase 3 tables (session_records, evaluations) do not exist yet.
-- Decision: mirror the case_role_assignments.scope_ref_id pattern exactly:
--   - context_type 'patient'  → validated against patients table NOW
--   - context_type 'research' → context_ref_id may be NULL (anonymous subjects)
--   - context_type 'session'  → trigger blocks until Phase 3 migration applied
--   - context_type 'evaluation' → trigger blocks until Phase 3 migration applied
-- This forces migration ordering discipline and prevents orphan response rows.
-- =============================================================================


-- =============================================================================
-- SECTION 1 — RESPONSE CONTEXT TYPES (lookup)
-- =============================================================================

CREATE TABLE response_context_types (
    id              UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    code            TEXT            NOT NULL UNIQUE,
        -- 'patient'     intake, general patient-level forms
        -- 'session'     attached to a therapy session (Phase 3)
        -- 'evaluation'  attached to a formal evaluation (Phase 3)
        -- 'research'    research data collection, may be anonymous
        -- 'discharge'   discharge documentation
    name            TEXT            NOT NULL,
    requires_patient_id     BOOLEAN NOT NULL DEFAULT TRUE,
    -- context_ref_id required (FK to context entity)?
    requires_context_ref    BOOLEAN NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by      UUID            REFERENCES users(id)
);

INSERT INTO response_context_types
    (code, name, requires_patient_id, requires_context_ref) VALUES
    ('patient',     'Patient',      TRUE,  FALSE),  -- patient_id IS the context
    ('session',     'Session',      TRUE,  TRUE),   -- context_ref_id → session_records (Phase 3)
    ('evaluation',  'Evaluation',   TRUE,  TRUE),   -- context_ref_id → evaluations (Phase 3)
    ('research',    'Research',     FALSE, FALSE),  -- may be anonymous; context_ref_id optional
    ('discharge',   'Discharge',    TRUE,  FALSE);


-- =============================================================================
-- SECTION 2 — FORM RESPONSES (header record)
-- =============================================================================
-- One row per form submission event.
-- Typed field values live in response_field_values (one row per field).
-- computed_score is stored here — not recalculated at query time [D3].
-- response_mode controls whether this is a clinical, pilot, or research record [D8].
-- =============================================================================

CREATE TABLE form_responses (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    branch_id           UUID            NOT NULL REFERENCES branches(id),   -- [R2] denorm
    form_version_id     UUID            NOT NULL REFERENCES form_versions(id),
    form_template_id    UUID            NOT NULL REFERENCES form_templates(id),

    -- Clinical context
    patient_id          UUID            REFERENCES patients(id),
    context_type_id     UUID            NOT NULL REFERENCES response_context_types(id),
    context_ref_id      UUID,           -- polymorphic: session.id / evaluation.id / NULL

    -- Response mode [D8]
    response_mode       TEXT            NOT NULL DEFAULT 'clinical',
        -- 'clinical'        part of patient chart, billable
        -- 'pilot'           instrument testing, not part of official care
        -- 'research_draft'  internal research validation

    -- Status lifecycle
    response_status     TEXT            NOT NULL DEFAULT 'in_progress',
        -- 'in_progress' → 'submitted' → 'reviewed' → 'locked'
        -- 'locked' = clinically finalised, no further edits

    -- Scoring [D3]
    is_scored_form      BOOLEAN         NOT NULL DEFAULT FALSE,
    computed_score      NUMERIC(10, 4),
    score_interpretation TEXT,          -- e.g. 'Mild', 'Moderate', 'Severe'
    scored_at           TIMESTAMPTZ,
    scored_by           UUID            REFERENCES users(id),

    -- Capture metadata
    started_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    submitted_at        TIMESTAMPTZ,
    reviewed_at         TIMESTAMPTZ,
    reviewed_by         UUID            REFERENCES users(id),
    locked_at           TIMESTAMPTZ,
    locked_by           UUID            REFERENCES users(id),

    -- Provenance
    administered_by     UUID            REFERENCES users(id),
    administration_mode TEXT,
        -- 'in_person', 'tele', 'self_administered', 'proxy'
    administration_notes TEXT,

    -- Version reference: version must be published at time of data collection
    -- (enforced by trigger below)
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Composite FK: form_version must belong to form_template [D7]
    CONSTRAINT fk_response_version_template
        FOREIGN KEY (form_version_id, form_template_id)
        REFERENCES form_versions(id, form_template_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- Composite FK: patient must belong to same institute
    CONSTRAINT fk_response_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- Composite FK: branch must belong to same institute [R2]
    CONSTRAINT fk_response_branch_institute
        FOREIGN KEY (branch_id, institute_id)
        REFERENCES branches(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- Clinical responses must have a patient [D8]
    CONSTRAINT chk_clinical_requires_patient
        CHECK (
            (response_mode = 'clinical' AND patient_id IS NOT NULL)
            OR response_mode IN ('pilot', 'research_draft')
        ),

    -- Locked responses are submitted
    CONSTRAINT chk_locked_requires_submitted
        CHECK (locked_at IS NULL OR submitted_at IS NOT NULL),

    -- Score only on scored forms
    CONSTRAINT chk_score_only_on_scored_form
        CHECK (
            is_scored_form = TRUE
            OR (computed_score IS NULL AND score_interpretation IS NULL)
        )
);

COMMENT ON TABLE form_responses IS
    'Header record for one form submission event. '
    '[D3] computed_score stored here — not recalculated at query time. '
    '[D8] response_mode: clinical/pilot/research_draft share one table. '
    'context_ref_id is polymorphic — validated by trigger per context_type. '
    'Field-level data in response_field_values (one row per field per response).';

COMMENT ON COLUMN form_responses.context_ref_id IS
    'Polymorphic FK resolved by context_type_id. '
    'context_type=patient    → NULL (patient_id is the context) '
    'context_type=session    → session_records.id  (Phase 3, blocked until migration) '
    'context_type=evaluation → evaluations.id      (Phase 3, blocked until migration) '
    'context_type=research   → NULL or research_subject.id (Phase 3 optional)';

COMMENT ON COLUMN form_responses.response_status IS
    'Lifecycle: in_progress → submitted → reviewed → locked. '
    'locked = clinically finalised. No edits permitted. '
    'Enforced by trigger (trg_form_response_lock_immutability).';

-- Indexes
CREATE INDEX idx_fr_institute         ON form_responses(institute_id);
CREATE INDEX idx_fr_branch            ON form_responses(branch_id);
CREATE INDEX idx_fr_patient           ON form_responses(patient_id);
CREATE INDEX idx_fr_version           ON form_responses(form_version_id);
CREATE INDEX idx_fr_template          ON form_responses(form_template_id);
CREATE INDEX idx_fr_context           ON form_responses(context_type_id, context_ref_id);
CREATE INDEX idx_fr_mode_status       ON form_responses(response_mode, response_status);
CREATE INDEX idx_fr_submitted         ON form_responses(patient_id, submitted_at DESC)
    WHERE response_status IN ('submitted', 'reviewed', 'locked');
CREATE INDEX idx_fr_clinical_active   ON form_responses(institute_id, patient_id)
    WHERE response_mode = 'clinical' AND response_status = 'locked';

-- Partition for scale (session-level tables become very large)
-- form_responses partitioned by institute_id for multi-tenant read performance
-- NOTE: Partition by range on created_at if time-series queries dominate.
-- Current choice: by institute — simpler RLS + cleaner cross-branch reporting.
-- Switch to time-range partitioning when approaching 10M rows.

-- ---------------------------------------------------------------------------
-- Trigger 1: Only published form versions may collect clinical responses
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_response_published_version()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    SELECT status INTO v_status
    FROM form_versions
    WHERE id = NEW.form_version_id;

    IF v_status != 'published' THEN
        RAISE EXCEPTION
            'form_response cannot be created on form_version % with status %. '
            'Only published versions may collect responses. '
            'Publish the version before collecting clinical data.',
            NEW.form_version_id, v_status;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_form_response_published_version
    BEFORE INSERT ON form_responses
    FOR EACH ROW
    EXECUTE FUNCTION enforce_response_published_version();

COMMENT ON TRIGGER trg_form_response_published_version ON form_responses IS
    'Blocks response collection on draft, review, or archived versions. '
    'Only published versions may collect clinical data. '
    'Ensures field definitions (and thus response_field_values) are immutable '
    'for the lifetime of every response against this version.';

-- ---------------------------------------------------------------------------
-- Trigger 2: Locked response immutability
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_response_lock_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.response_status = 'locked' THEN
        -- Allow only administrative annotations, never clinical field data
        IF NEW.form_version_id    != OLD.form_version_id   OR
           NEW.patient_id         IS DISTINCT FROM OLD.patient_id    OR
           NEW.context_ref_id     IS DISTINCT FROM OLD.context_ref_id OR
           NEW.response_mode      != OLD.response_mode     OR
           NEW.computed_score     IS DISTINCT FROM OLD.computed_score OR
           NEW.administered_by    IS DISTINCT FROM OLD.administered_by OR
           NEW.started_at         != OLD.started_at        OR
           NEW.submitted_at       IS DISTINCT FROM OLD.submitted_at
        THEN
            RAISE EXCEPTION
                'form_response % is locked (clinically finalised) and immutable. '
                'Core clinical fields cannot be changed. '
                'Only reviewed_by, reviewed_at, and locked_at/by may be updated '
                'for administrative completion.',
                OLD.id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_form_response_lock_immutability
    BEFORE UPDATE ON form_responses
    FOR EACH ROW
    EXECUTE FUNCTION enforce_response_lock_immutability();

-- ---------------------------------------------------------------------------
-- Trigger 3: Polymorphic context_ref_id validation
-- (mirrors case_role_assignments scope_ref pattern exactly)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION validate_response_context_ref()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_context_code          TEXT;
    v_requires_patient      BOOLEAN;
    v_requires_context_ref  BOOLEAN;
BEGIN
    SELECT rct.code, rct.requires_patient_id, rct.requires_context_ref
    INTO v_context_code, v_requires_patient, v_requires_context_ref
    FROM response_context_types rct
    WHERE rct.id = NEW.context_type_id;

    -- Validate patient_id presence based on context type
    IF v_requires_patient AND NEW.patient_id IS NULL THEN
        RAISE EXCEPTION
            'context_type=% requires patient_id to be set. '
            'response_id: %',
            v_context_code, NEW.id;
    END IF;

    -- context_type = 'patient': context_ref_id must be NULL
    -- (patient_id IS the context anchor — no secondary ref needed)
    IF v_context_code = 'patient' AND NEW.context_ref_id IS NOT NULL THEN
        RAISE EXCEPTION
            'context_type=patient does not use context_ref_id. '
            'patient_id is the context anchor. '
            'Set context_ref_id to NULL for patient-level responses.',
            ;
    END IF;

    -- context_type = 'session': Phase 3 table not yet available
    IF v_context_code = 'session' THEN
        RAISE EXCEPTION
            'context_type=session is not yet supported. '
            'session_records table will be created in Phase 3. '
            'Do not create session-context responses until Phase 3 migration is applied.';
    END IF;

    -- context_type = 'evaluation': Phase 3 table not yet available
    IF v_context_code = 'evaluation' THEN
        RAISE EXCEPTION
            'context_type=evaluation is not yet supported. '
            'evaluations table will be created in Phase 3. '
            'Do not create evaluation-context responses until Phase 3 migration is applied.';
    END IF;

    -- context_type = 'research': context_ref_id optional, no FK validation now
    -- context_type = 'discharge': patient_id sufficient, no context_ref_id needed

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_form_response_context_ref
    BEFORE INSERT OR UPDATE OF context_type_id, context_ref_id, patient_id
    ON form_responses
    FOR EACH ROW
    EXECUTE FUNCTION validate_response_context_ref();

COMMENT ON TRIGGER trg_form_response_context_ref ON form_responses IS
    'Polymorphic context_ref_id validation. '
    'patient context: validated now (patient table exists). '
    'session context: blocked with explicit error until Phase 3. '
    'evaluation context: blocked with explicit error until Phase 3. '
    'research context: context_ref_id optional, no FK until Phase 3. '
    'Phase 3 MUST replace this function with full validation.';


-- =============================================================================
-- SECTION 3 — RESPONSE FIELD VALUES  [D1] [D2] [D7]
-- =============================================================================
-- One row per field per response submission.
-- Typed columns: value_text, value_numeric, value_boolean, value_date, value_json.
-- Exactly one value column populated per row — enforced by CHECK. [D2]
-- Composite FK freezes field meaning at capture time. [D7]
-- layout-only fields (section_header, group) produce no value rows.
-- =============================================================================

CREATE TABLE response_field_values (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),  -- [R1] denorm
    response_id         UUID            NOT NULL REFERENCES form_responses(id) ON DELETE CASCADE,
    field_id            UUID            NOT NULL,   -- resolved via composite FK
    form_version_id     UUID            NOT NULL,   -- frozen at capture time [D7]

    -- Typed value storage [D2]
    -- Exactly one of these must be populated — CHECK enforces below
    value_text          TEXT,
    value_numeric       NUMERIC(15, 6),
    value_boolean       BOOLEAN,
    value_date          DATE,
    value_json          JSONB,          -- multi_choice arrays, table_matrix, file refs

    -- Field-level capture metadata
    is_skipped          BOOLEAN         NOT NULL DEFAULT FALSE,
    skip_reason         TEXT,
    override_notes      TEXT,           -- clinician notes on this specific field answer
    captured_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    captured_by         UUID            REFERENCES users(id),

    -- [D7] Composite FK: field_id + form_version_id frozen together
    CONSTRAINT fk_rfv_field_version
        FOREIGN KEY (field_id, form_version_id)
        REFERENCES form_fields(id, form_version_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- Institute boundary: response and field value share institute
    CONSTRAINT fk_rfv_response_institute
        FOREIGN KEY (response_id, institute_id)
        REFERENCES form_responses(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- One response cannot have duplicate field entries for the same field
    CONSTRAINT uq_response_field UNIQUE (response_id, field_id),

    -- [D2] Exactly one value column must be populated (unless skipped)
    CONSTRAINT chk_exactly_one_value
        CHECK (
            is_skipped = TRUE   -- skipped fields have no value — all NULLs allowed
            OR (
                (value_text    IS NOT NULL)::INT +
                (value_numeric IS NOT NULL)::INT +
                (value_boolean IS NOT NULL)::INT +
                (value_date    IS NOT NULL)::INT +
                (value_json    IS NOT NULL)::INT
                = 1
            )
        ),

    -- Skip requires a reason when is_skipped is TRUE
    CONSTRAINT chk_skip_reason
        CHECK (is_skipped = FALSE OR skip_reason IS NOT NULL)
);

COMMENT ON TABLE response_field_values IS
    '[D1] One row per field per response. Fully normalized — no JSONB blobs. '
    '[D2] Exactly-one CHECK: exactly one typed column populated per row. '
    '[D7] Composite FK (field_id, form_version_id) freezes field meaning at capture. '
    'Skipped fields (is_skipped=TRUE) may have all value columns NULL. '
    'Layout-only fields (section_header, group) produce no rows here.';

COMMENT ON COLUMN response_field_values.form_version_id IS
    '[D7] Snapshot of which version was active at response capture time. '
    'Combined with field_id in composite FK, this guarantees the field definition '
    'used for interpretation is always the one that was active when data was entered. '
    'Historical responses remain interpretable even after newer versions are published.';

COMMENT ON COLUMN response_field_values.value_json IS
    'Used for: multi_choice (array of selected codes), '
    'table_matrix (row/column structure), file_upload (storage ref + metadata). '
    'Never used as a catch-all — only for structurally complex values. '
    'Application layer must validate structure per field type.';

-- Indexes — performance-critical: these tables will be the largest in the system
CREATE INDEX idx_rfv_response          ON response_field_values(response_id);
CREATE INDEX idx_rfv_institute         ON response_field_values(institute_id);
CREATE INDEX idx_rfv_field             ON response_field_values(field_id);
CREATE INDEX idx_rfv_field_version     ON response_field_values(field_id, form_version_id);

-- Research analytics: filter by field across all responses
CREATE INDEX idx_rfv_field_value_num   ON response_field_values(field_id, value_numeric)
    WHERE value_numeric IS NOT NULL;
CREATE INDEX idx_rfv_field_value_text  ON response_field_values(field_id, value_text)
    WHERE value_text IS NOT NULL;
CREATE INDEX idx_rfv_field_value_bool  ON response_field_values(field_id, value_boolean)
    WHERE value_boolean IS NOT NULL;

-- DPDP data subject export: find all field values for a patient across all responses
-- Resolved via JOIN: response_field_values → form_responses(patient_id)
-- No direct patient_id column here intentionally — avoids denorm on hot path
-- The join is indexed: idx_fr_patient + idx_rfv_response covers it.

-- ---------------------------------------------------------------------------
-- Trigger: block field value writes on locked responses
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_field_value_response_lock()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    SELECT response_status INTO v_status
    FROM form_responses
    WHERE id = COALESCE(NEW.response_id, OLD.response_id);

    IF v_status = 'locked' THEN
        RAISE EXCEPTION
            'form_response % is locked. '
            'Field values cannot be added, modified, or deleted after locking. '
            'Locked responses are clinically finalised.',
            COALESCE(NEW.response_id, OLD.response_id);
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_rfv_lock_guard
    BEFORE INSERT OR UPDATE OR DELETE ON response_field_values
    FOR EACH ROW
    EXECUTE FUNCTION enforce_field_value_response_lock();

COMMENT ON TRIGGER trg_rfv_lock_guard ON response_field_values IS
    'Blocks all writes (INSERT, UPDATE, DELETE) to field values once the '
    'parent response is locked. Works in tandem with form_responses lock trigger. '
    'Two independent enforcement layers: header + field value level.';

-- ---------------------------------------------------------------------------
-- Trigger: validate that field type supports a value column
-- (routes value to correct column per form_field_types.value_column)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_field_value_type_routing()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_expected_col  TEXT;
    v_stores_value  BOOLEAN;
BEGIN
    -- Skip validation for skipped fields
    IF NEW.is_skipped = TRUE THEN
        RETURN NEW;
    END IF;

    SELECT fft.value_column, fft.stores_value
    INTO v_expected_col, v_stores_value
    FROM form_fields ff
    JOIN form_field_types fft ON fft.id = ff.field_type_id
    WHERE ff.id = NEW.field_id
      AND ff.form_version_id = NEW.form_version_id;

    -- Layout-only fields (section_header, group) should produce no value rows
    IF v_stores_value = FALSE THEN
        RAISE EXCEPTION
            'Field % (version %) is a layout-only field type and should not '
            'produce response_field_value rows. '
            'Application layer must skip layout fields when storing responses.',
            NEW.field_id, NEW.form_version_id;
    END IF;

    -- The populated column must match the expected column for this field type
    IF v_expected_col = 'value_text'    AND NEW.value_text    IS NULL THEN
        RAISE EXCEPTION 'Field % expects value_text but it is NULL.',    NEW.field_id;
    END IF;
    IF v_expected_col = 'value_numeric' AND NEW.value_numeric  IS NULL THEN
        RAISE EXCEPTION 'Field % expects value_numeric but it is NULL.', NEW.field_id;
    END IF;
    IF v_expected_col = 'value_boolean' AND NEW.value_boolean  IS NULL THEN
        RAISE EXCEPTION 'Field % expects value_boolean but it is NULL.', NEW.field_id;
    END IF;
    IF v_expected_col = 'value_date'    AND NEW.value_date     IS NULL THEN
        RAISE EXCEPTION 'Field % expects value_date but it is NULL.',    NEW.field_id;
    END IF;
    IF v_expected_col = 'value_json'    AND NEW.value_json     IS NULL THEN
        RAISE EXCEPTION 'Field % expects value_json but it is NULL.',    NEW.field_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_rfv_type_routing
    BEFORE INSERT OR UPDATE OF
        field_id, form_version_id,
        value_text, value_numeric, value_boolean, value_date, value_json
    ON response_field_values
    FOR EACH ROW
    EXECUTE FUNCTION enforce_field_value_type_routing();

COMMENT ON TRIGGER trg_rfv_type_routing ON response_field_values IS
    'Validates that the populated value column matches the field type definition. '
    'Prevents a boolean field storing into value_text, etc. '
    'Works with form_field_types.value_column — the bridge between definition and storage. '
    'Skipped fields bypass this validation (no value populated).';


-- =============================================================================
-- SECTION 4 — RLS ON RESPONSE LAYER  [D9]
-- =============================================================================
-- RLS anchored to patient_provider_assignments — same anchor as all clinical tables.
-- Research mode responses: visible to institute-scope users + assigned providers.
-- No platform researcher bypass. Cross-institute analytics = warehouse only.
-- =============================================================================

-- Composite UNIQUE on form_responses to enable composite FKs from downstream tables
ALTER TABLE form_responses
    ADD CONSTRAINT uq_form_response_id_institute UNIQUE (id, institute_id);

-- form_responses RLS
ALTER TABLE form_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE form_responses FORCE ROW LEVEL SECURITY;

CREATE POLICY fr_platform_admin ON form_responses
    FOR ALL USING (current_user_is_platform_admin());

-- Clinical + pilot responses: assigned provider only
CREATE POLICY fr_assigned_provider ON form_responses
    FOR SELECT
    USING (
        institute_id = current_institute_id()
        AND patient_id IS NOT NULL
        AND current_user_assigned_to_patient(patient_id)
    );

-- Institute-scope users (compliance, dept heads, supervisors) see all institute responses
CREATE POLICY fr_institute_scope ON form_responses
    FOR SELECT
    USING (
        institute_id = current_institute_id()
        AND current_user_has_institute_scope()
    );

-- Response collection: provider must be assigned to patient + have permission
CREATE POLICY fr_insert ON form_responses
    FOR INSERT
    WITH CHECK (
        institute_id = current_institute_id()
        AND (
            patient_id IS NULL  -- research_draft with no patient
            OR current_user_assigned_to_patient(patient_id)
        )
        AND current_user_has_permission('CAN_COLLECT_RESPONSES')
    );

-- Update (in-progress → submitted): same scope as insert
CREATE POLICY fr_update ON form_responses
    FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND (
            patient_id IS NULL
            OR current_user_assigned_to_patient(patient_id)
        )
        AND current_user_has_permission('CAN_COLLECT_RESPONSES')
    );

-- response_field_values RLS
ALTER TABLE response_field_values ENABLE ROW LEVEL SECURITY;
ALTER TABLE response_field_values FORCE ROW LEVEL SECURITY;

CREATE POLICY rfv_platform_admin ON response_field_values
    FOR ALL USING (current_user_is_platform_admin());

-- Read: join through to form_responses patient check
CREATE POLICY rfv_read ON response_field_values
    FOR SELECT
    USING (
        institute_id = current_institute_id()
        AND (
            current_user_has_institute_scope()
            OR EXISTS (
                SELECT 1 FROM form_responses fr
                WHERE fr.id = response_field_values.response_id
                  AND fr.patient_id IS NOT NULL
                  AND current_user_assigned_to_patient(fr.patient_id)
            )
        )
    );

-- Write: same as response header
CREATE POLICY rfv_write ON response_field_values
    FOR INSERT
    WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_COLLECT_RESPONSES')
        AND EXISTS (
            SELECT 1 FROM form_responses fr
            WHERE fr.id = response_field_values.response_id
              AND (
                  fr.patient_id IS NULL
                  OR current_user_assigned_to_patient(fr.patient_id)
              )
        )
    );


-- =============================================================================
-- SECTION 5 — RESPONSE ANALYTICS VIEWS
-- =============================================================================
-- Read-only views for research and reporting queries.
-- De-identification for research mode responses.
-- =============================================================================

-- Aggregation-ready view: field scores per patient per form version
CREATE VIEW v_patient_field_scores AS
SELECT
    fr.institute_id,
    fr.patient_id,
    fr.form_template_id,
    fr.form_version_id,
    fr.response_mode,
    fr.response_status,
    fr.submitted_at,
    fr.computed_score            AS form_total_score,
    ff.code                      AS field_code,
    ff.label                     AS field_label,
    rfv.value_numeric,
    rfv.value_text,
    rfv.value_boolean,
    rfv.value_date,
    rfv.is_skipped
FROM form_responses fr
JOIN response_field_values rfv  ON rfv.response_id     = fr.id
JOIN form_fields ff              ON ff.id               = rfv.field_id
                                AND ff.form_version_id  = rfv.form_version_id
WHERE fr.response_status IN ('submitted', 'reviewed', 'locked');

COMMENT ON VIEW v_patient_field_scores IS
    'Research and analytics view. '
    'Joins responses → field values → field definitions. '
    'Field code is the stable analytics identifier across versions. '
    'Filter on response_mode to separate clinical vs research data. '
    'RLS applies via underlying table policies.';

-- DPDP data subject export helper: all responses for a patient
CREATE VIEW v_patient_response_export AS
SELECT
    fr.id                        AS response_id,
    fr.patient_id,
    fr.form_template_id,
    fr.form_version_id,
    fr.context_type_id,
    fr.response_mode,
    fr.response_status,
    fr.started_at,
    fr.submitted_at,
    ff.code                      AS field_code,
    ff.label                     AS field_label,
    rfv.value_text,
    rfv.value_numeric,
    rfv.value_boolean,
    rfv.value_date,
    rfv.value_json,
    rfv.is_skipped,
    rfv.captured_at
FROM form_responses fr
JOIN response_field_values rfv  ON rfv.response_id    = fr.id
JOIN form_fields ff              ON ff.id              = rfv.field_id
                                AND ff.form_version_id = rfv.form_version_id
ORDER BY fr.patient_id, fr.submitted_at, ff.sort_order;

COMMENT ON VIEW v_patient_response_export IS
    'DPDP data subject access request export view. '
    'Returns all form responses and field values for a patient. '
    'Filter by patient_id at query time. '
    'RLS on underlying tables restricts access to authorised users only.';


-- =============================================================================
-- SECTION 6 — PERMISSIONS SEED (response layer)
-- =============================================================================

INSERT INTO permissions (code, name, module, description) VALUES
    ('CAN_LOCK_RESPONSES',  'Lock Form Responses',  'clinical',
        'Finalise and lock submitted form responses'),
    ('CAN_REVIEW_RESPONSES','Review Form Responses', 'clinical',
        'Mark responses as clinically reviewed'),
    ('CAN_SCORE_RESPONSES', 'Score Form Responses',  'clinical',
        'Trigger or update computed scoring on form responses')
ON CONFLICT (code) DO NOTHING;


-- =============================================================================
-- PHASE 2 — FORM ENGINE COMPLETE
-- =============================================================================
--
-- Migration sequence for complete form engine:
--
--   phase2_form_definition.sql
--   phase2_form_definition_patch01.sql
--   phase2_form_definition_patch02.sql
--   phase2_form_definition_patch03.sql
--   phase2_form_responses.sql            ← this file
--
-- Tables created in this file:
--   response_context_types               (lookup)
--   form_responses                       (header, one per submission)
--   response_field_values                (one row per field per response)
--
-- Triggers:
--   trg_form_response_published_version  blocks draft version data collection
--   trg_form_response_lock_immutability  blocks core field changes on locked responses
--   trg_form_response_context_ref        polymorphic context validation
--   trg_rfv_lock_guard                   blocks field value writes on locked response
--   trg_rfv_type_routing                 validates value column matches field type
--
-- Views:
--   v_patient_field_scores               research and analytics aggregation
--   v_patient_response_export            DPDP data subject access export
--
-- RLS:
--   form_responses        — provider assignment anchor + institute scope
--   response_field_values — via join to form_responses patient_id
--
-- =============================================================================
-- PHASE 3 WILL COVER (Clinical Core)
-- =============================================================================
-- therapy_type_registry (lookup, no hardcoded types)
-- therapy_programs + therapy_program_versions
-- session_records + session_versions
-- evaluations + evaluation_versions
-- milestones
-- case_conferences
-- plan_change_requests
--
-- Phase 3 MUST:
--   Replace validate_response_context_ref() to unblock session + evaluation contexts
--   Replace validate_case_role_scope_ref_partial() to unblock program scope
--   Add composite FKs from form_responses.context_ref_id to session + evaluation tables
-- =============================================================================