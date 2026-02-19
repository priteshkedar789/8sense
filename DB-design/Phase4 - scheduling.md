-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 4 — SCHEDULING SUBSYSTEM
-- =============================================================================
-- Apply after: all Phase 1, 2, and 3 files
-- =============================================================================
--
-- ARCHITECTURAL PRINCIPLE
-- ─────────────────────────────────────────────────────────────────────────────
-- A scheduled slot is mutable pre-clinical intent.
-- A session_record is immutable clinical fact.
-- These are structurally separated. The promotion boundary is atomic
-- and one-directional: a slot becomes a session_record exactly once.
--
-- SLOT LIFECYCLE:
--   scheduled → confirmed → checked_in → converted (→ session_record created)
--                         ↘ no_show
--            ↘ cancelled
--            ↘ rescheduled (original slot → new slot)
--
-- PROMOTION EVENT: slot_status = 'checked_in' → 'converted'
--   Trigger creates session_record (status='in_progress')
--   Slot becomes partially frozen: patient/provider/program/time immutable
--   session_id FK set on slot — one-directional link
--
-- CONFLICT DETECTION: PostgreSQL EXCLUSION CONSTRAINT using tstzrange
--   Blocks double-booking at structural level (not application-layer check)
--   Applied only to active slots (scheduled/confirmed/checked_in)
--
-- RECURRING PATTERNS: separate table, generates slots independently
--   Pattern changes never mutate historical slots
--   Slots are autonomous rows after generation
--
-- RESOURCE SCHEDULING: out of scope for Phase 4
--   Rooms/equipment: Phase 5 sub-phase
-- =============================================================================


-- =============================================================================
-- SECTION 1 — SCHEDULING CONFIGURATION LOOKUPS
-- =============================================================================

CREATE TABLE slot_status_types (
    id          UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    code        TEXT        NOT NULL UNIQUE,
    name        TEXT        NOT NULL,
    is_terminal BOOLEAN     NOT NULL DEFAULT FALSE,
    sort_order  INTEGER     NOT NULL DEFAULT 0
);

INSERT INTO slot_status_types (code, name, is_terminal, sort_order) VALUES
    ('scheduled',   'Scheduled',              FALSE, 1),
    ('confirmed',   'Confirmed',              FALSE, 2),
    ('checked_in',  'Checked In',             FALSE, 3),
    ('converted',   'Converted to Session',   TRUE,  4),
    ('no_show',     'No Show',                TRUE,  5),
    ('cancelled',   'Cancelled',              TRUE,  6),
    ('rescheduled', 'Rescheduled',            TRUE,  7);

CREATE TABLE cancellation_reason_types (
    id      UUID    PRIMARY KEY DEFAULT generate_uuidv7(),
    code    TEXT    NOT NULL UNIQUE,
    name    TEXT    NOT NULL,
    responsible_party TEXT    -- 'provider', 'patient', 'institute', 'external'
);

INSERT INTO cancellation_reason_types (code, name, responsible_party) VALUES
    ('patient_sick',            'Patient Illness',              'patient'),
    ('family_unavailable',      'Family Unavailability',        'patient'),
    ('patient_noncompliance',   'Patient Non-compliance',       'patient'),
    ('provider_sick',           'Provider Illness',             'provider'),
    ('provider_training',       'Provider Training/Leave',      'provider'),
    ('institute_holiday',       'Institute Holiday',            'institute'),
    ('facility_issue',          'Facility/Utility Issue',       'institute'),
    ('weather',                 'Weather/Emergency',            'external'),
    ('other',                   'Other',                        NULL);


-- =============================================================================
-- SECTION 2 — SCHEDULED SLOTS
-- =============================================================================

CREATE TABLE scheduled_slots (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    branch_id           UUID            NOT NULL REFERENCES branches(id),
    department_id       UUID            REFERENCES departments(id),

    -- Clinical anchors
    patient_id          UUID            NOT NULL REFERENCES patients(id),
    provider_id         UUID            NOT NULL,   -- user_institute_memberships.user_id
    therapy_program_id  UUID            REFERENCES therapy_programs(id),
    therapy_type_id     UUID            NOT NULL REFERENCES therapy_type_registry(id),

    -- Scheduling
    scheduled_start     TIMESTAMPTZ     NOT NULL,
    scheduled_end       TIMESTAMPTZ     NOT NULL,
    duration_minutes    INTEGER
        GENERATED ALWAYS AS (
            EXTRACT(EPOCH FROM (scheduled_end - scheduled_start)) / 60
        ) STORED,
    modality            TEXT            NOT NULL DEFAULT 'in_person',
        -- 'in_person','tele','home_visit','school_visit','community'

    -- Slot lifecycle
    slot_status         TEXT            NOT NULL DEFAULT 'scheduled',
    cancellation_reason_id UUID         REFERENCES cancellation_reason_types(id),
    cancellation_notes  TEXT,
    rescheduled_to_slot_id UUID,        -- forward link if rescheduled (self-ref added below)

    -- Promotion link (set when slot is converted to session_record)
    session_id          UUID            REFERENCES session_records(id),

    -- Recurring pattern origin (nullable — NULL for manually created slots)
    recurring_pattern_id UUID,          -- FK added after recurring_patterns created

    -- Confirmation tracking
    confirmed_at        TIMESTAMPTZ,
    confirmed_by        UUID            REFERENCES users(id),
    checked_in_at       TIMESTAMPTZ,
    checked_in_by       UUID            REFERENCES users(id),
    converted_at        TIMESTAMPTZ,

    -- Amendment / reschedule chain
    rescheduled_from_slot_id UUID,      -- back-link to original slot

    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- ── Composite institute boundary FKs ─────────────────────────────────────
    CONSTRAINT fk_ss_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_ss_branch_institute
        FOREIGN KEY (branch_id, institute_id)
        REFERENCES branches(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_ss_provider_institute
        FOREIGN KEY (provider_id, institute_id)
        REFERENCES user_institute_memberships(user_id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_ss_program_institute
        FOREIGN KEY (therapy_program_id, institute_id)
        REFERENCES therapy_programs(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- ── Structural constraints ────────────────────────────────────────────────
    CONSTRAINT chk_ss_time_order
        CHECK (scheduled_end > scheduled_start),

    CONSTRAINT chk_ss_status_valid
        CHECK (slot_status IN ('scheduled','confirmed','checked_in','converted','no_show','cancelled','rescheduled')),

    CONSTRAINT chk_ss_cancellation_reason_when_cancelled
        CHECK (slot_status NOT IN ('cancelled','no_show') OR cancellation_reason_id IS NOT NULL),

    CONSTRAINT chk_ss_session_id_only_when_converted
        CHECK (slot_status = 'converted' OR session_id IS NULL),

    CONSTRAINT chk_ss_converted_requires_session
        CHECK (slot_status != 'converted' OR session_id IS NOT NULL),

    CONSTRAINT chk_ss_no_self_reschedule
        CHECK (rescheduled_to_slot_id IS NULL OR rescheduled_to_slot_id != id),

    -- Timestamp ordering
    CONSTRAINT chk_ss_confirmed_at_timing
        CHECK (confirmed_at IS NULL OR slot_status IN ('confirmed','checked_in','converted')),

    CONSTRAINT chk_ss_checked_in_at_timing
        CHECK (checked_in_at IS NULL OR slot_status IN ('checked_in','converted')),

    CONSTRAINT chk_ss_converted_at_timing
        CHECK (converted_at IS NULL OR slot_status = 'converted'),

    -- Enable composite FKs from downstream tables
    CONSTRAINT uq_ss_id_institute UNIQUE (id, institute_id),

    -- One session per slot (each session comes from exactly one slot)
    CONSTRAINT uq_ss_session_id UNIQUE (session_id)
);

-- Self-referential FK for reschedule chain
ALTER TABLE scheduled_slots
    ADD CONSTRAINT fk_ss_rescheduled_to
    FOREIGN KEY (rescheduled_to_slot_id)
    REFERENCES scheduled_slots(id)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE scheduled_slots
    ADD CONSTRAINT fk_ss_rescheduled_from
    FOREIGN KEY (rescheduled_from_slot_id)
    REFERENCES scheduled_slots(id)
    DEFERRABLE INITIALLY DEFERRED;

COMMENT ON TABLE scheduled_slots IS
    'Pre-clinical mutable scheduling layer. '
    'Slots are fully mutable until converted. '
    'Conversion to session_record is atomic and one-directional. '
    'Once session_id IS NOT NULL: patient/provider/program/time immutable. '
    'Conflict detection via EXCLUSION CONSTRAINT on tstzrange (active slots only). '
    'Reschedule chain: rescheduled_from_slot_id ↔ rescheduled_to_slot_id. '
    'Resource scheduling (rooms/equipment): Phase 5.';

COMMENT ON COLUMN scheduled_slots.session_id IS
    'Set by trg_slot_promote_to_session on checked_in → converted transition. '
    'One-directional: slot references session, session does NOT reference slot. '
    'Clinical layer is unaware of scheduling layer. '
    'uq_ss_session_id ensures one session per slot (no duplicate promotion).';


-- =============================================================================
-- SECTION 3 — CONFLICT DETECTION (EXCLUSION CONSTRAINT)
-- =============================================================================
-- Blocks double-booking at the structural level.
-- Uses PostgreSQL EXCLUSION CONSTRAINT with tstzrange.
-- Applied only to active slots (scheduled/confirmed/checked_in).
-- Terminal slots (converted/no_show/cancelled/rescheduled) are excluded.
-- =============================================================================

-- Requires btree_gist extension for mixed type exclusion constraints
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Provider double-booking prevention (institute-scoped)
CREATE EXTENSION IF NOT EXISTS btree_gist;

ALTER TABLE scheduled_slots
    ADD CONSTRAINT excl_provider_no_overlap
    EXCLUDE USING gist (
        institute_id    WITH =,
        provider_id     WITH =,
        tstzrange(scheduled_start, scheduled_end, '[)') WITH &&
    )
    WHERE (slot_status IN ('scheduled', 'confirmed', 'checked_in'));

COMMENT ON CONSTRAINT excl_provider_no_overlap ON scheduled_slots IS
    'Structural double-booking prevention. '
    'Provider cannot have two overlapping active slots in the same institute. '
    'Applies to scheduled/confirmed/checked_in only — terminal slots excluded. '
    'Half-open range [scheduled_start, scheduled_end) used: back-to-back sessions allowed. '
    'Resource (room) conflict detection: Phase 5.';

-- Patient double-booking prevention
ALTER TABLE scheduled_slots
    ADD CONSTRAINT excl_patient_no_overlap
    EXCLUDE USING gist (
        institute_id    WITH =,
        patient_id      WITH =,
        tstzrange(scheduled_start, scheduled_end, '[)') WITH &&
    )
    WHERE (slot_status IN ('scheduled', 'confirmed', 'checked_in'));

COMMENT ON CONSTRAINT excl_patient_no_overlap ON scheduled_slots IS
    'Patient cannot have two overlapping active sessions in the same institute. '
    'Applies same exclusion logic as provider constraint.';


-- =============================================================================
-- SECTION 4 — SLOT LIFECYCLE TRIGGERS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Trigger A: Forward-only status transition enforcement
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_slot_lifecycle_transitions()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.slot_status = OLD.slot_status THEN RETURN NEW; END IF;

    -- From scheduled: can advance to confirmed, cancelled, or rescheduled
    IF OLD.slot_status = 'scheduled' AND
       NEW.slot_status NOT IN ('scheduled','confirmed','cancelled','rescheduled') THEN
        RAISE EXCEPTION
            'scheduled_slot %: invalid transition scheduled → %. '
            'Permitted: confirmed, cancelled, rescheduled.',
            OLD.id, NEW.slot_status;
    END IF;

    -- From confirmed: can advance to checked_in, no_show, cancelled, rescheduled
    IF OLD.slot_status = 'confirmed' AND
       NEW.slot_status NOT IN ('confirmed','checked_in','no_show','cancelled','rescheduled') THEN
        RAISE EXCEPTION
            'scheduled_slot %: invalid transition confirmed → %. '
            'Permitted: checked_in, no_show, cancelled, rescheduled.',
            OLD.id, NEW.slot_status;
    END IF;

    -- From checked_in: can only convert (front desk has confirmed physical attendance)
    IF OLD.slot_status = 'checked_in' AND
       NEW.slot_status NOT IN ('checked_in','converted') THEN
        RAISE EXCEPTION
            'scheduled_slot %: invalid transition checked_in → %. '
            'Only checked_in → converted is permitted once patient is present.',
            OLD.id, NEW.slot_status;
    END IF;

    -- Terminal states: no further transitions
    IF OLD.slot_status IN ('converted','no_show','cancelled','rescheduled') THEN
        RAISE EXCEPTION
            'scheduled_slot %: status=% is terminal. No further transitions permitted.',
            OLD.id, OLD.slot_status;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_slot_lifecycle
    BEFORE UPDATE OF slot_status
    ON scheduled_slots
    FOR EACH ROW
    EXECUTE FUNCTION enforce_slot_lifecycle_transitions();

-- ---------------------------------------------------------------------------
-- Trigger B: Partial freeze on converted slots
-- Identity facts (patient/provider/program/time) immutable post-conversion
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_slot_post_conversion_freeze()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Once converted (session_id set), identity and time facts are frozen
    IF OLD.session_id IS NOT NULL THEN
        IF NEW.patient_id           IS DISTINCT FROM OLD.patient_id           OR
           NEW.provider_id          IS DISTINCT FROM OLD.provider_id          OR
           NEW.institute_id         != OLD.institute_id                        OR
           NEW.branch_id            IS DISTINCT FROM OLD.branch_id            OR
           NEW.therapy_program_id   IS DISTINCT FROM OLD.therapy_program_id   OR
           NEW.therapy_type_id      IS DISTINCT FROM OLD.therapy_type_id      OR
           NEW.scheduled_start      != OLD.scheduled_start                    OR
           NEW.scheduled_end        != OLD.scheduled_end
        THEN
            RAISE EXCEPTION
                'scheduled_slot % has been converted to session_record % and is partially frozen. '
                'patient, provider, institute, branch, program, type, and scheduled times '
                'cannot change after conversion. '
                'These facts now anchor an immutable clinical record.',
                OLD.id, OLD.session_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_slot_post_conversion_freeze
    BEFORE UPDATE ON scheduled_slots
    FOR EACH ROW
    EXECUTE FUNCTION enforce_slot_post_conversion_freeze();

-- ---------------------------------------------------------------------------
-- Trigger C: PROMOTION — checked_in → converted creates session_record
-- The most critical trigger in Phase 4.
-- Atomically creates session_record and sets session_id on slot.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION promote_slot_to_session()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_session_id UUID;
BEGIN
    -- Only fire on checked_in → converted transition
    IF NOT (OLD.slot_status = 'checked_in' AND NEW.slot_status = 'converted') THEN
        RETURN NEW;
    END IF;

    -- Guard: should not already have a session_id
    IF OLD.session_id IS NOT NULL THEN
        RAISE EXCEPTION
            'scheduled_slot % already has session_id=%. Double promotion detected. '
            'Each slot may only be promoted to a session once.',
            OLD.id, OLD.session_id;
    END IF;

    v_session_id := generate_uuidv7();

    -- Create the session_record atomically with the slot status transition
    INSERT INTO session_records (
        id,
        institute_id,
        branch_id,
        department_id,
        patient_id,
        provider_id,
        therapy_program_id,
        therapy_type_id,
        scheduled_start,
        scheduled_end,
        actual_start,
        modality,
        attendance_status,
        status,
        note_status,
        created_by
    ) VALUES (
        v_session_id,
        NEW.institute_id,
        NEW.branch_id,
        NEW.department_id,
        NEW.patient_id,
        NEW.provider_id,
        NEW.therapy_program_id,
        NEW.therapy_type_id,
        NEW.scheduled_start,
        NEW.scheduled_end,
        NOW(),                      -- actual_start = check-in time
        NEW.modality,
        'attended',
        'in_progress',
        'draft',
        NEW.checked_in_by           -- front desk actor as creator
    );

    -- Link the session back to this slot on the NEW row
    NEW.session_id      := v_session_id;
    NEW.converted_at    := NOW();

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_slot_promote_to_session
    BEFORE UPDATE OF slot_status
    ON scheduled_slots
    FOR EACH ROW
    EXECUTE FUNCTION promote_slot_to_session();

COMMENT ON TRIGGER trg_slot_promote_to_session ON scheduled_slots IS
    'PROMOTION BOUNDARY: checked_in → converted. '
    'Atomically creates session_record (status=in_progress) and sets session_id. '
    'actual_start set to NOW() (check-in time). '
    'attendance_status=attended on the new session_record. '
    'Guard prevents double-promotion if trigger fires twice (should not happen, '
    'but uq_ss_session_id UNIQUE constraint is the structural backstop). '
    'After this trigger: session_record lifecycle is fully independent of slot.';

-- ---------------------------------------------------------------------------
-- Trigger D: Reschedule chain integrity
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_reschedule_integrity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_original_inst UUID;
BEGIN
    IF NEW.rescheduled_from_slot_id IS NULL THEN RETURN NEW; END IF;

    SELECT institute_id INTO v_original_inst
    FROM scheduled_slots
    WHERE id = NEW.rescheduled_from_slot_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Reschedule error: original slot % not found.',
            NEW.rescheduled_from_slot_id;
    END IF;

    IF v_original_inst != NEW.institute_id THEN
        RAISE EXCEPTION
            'Reschedule error: original slot % belongs to a different institute.',
            NEW.rescheduled_from_slot_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reschedule_integrity
    BEFORE INSERT OR UPDATE OF rescheduled_from_slot_id
    ON scheduled_slots
    FOR EACH ROW
    EXECUTE FUNCTION enforce_reschedule_integrity();


-- =============================================================================
-- SECTION 5 — RECURRING SCHEDULE PATTERNS
-- =============================================================================
-- Generates scheduled_slots at creation or via a batch job.
-- Pattern changes never mutate historical slots.
-- Slots are autonomous rows after generation.
-- =============================================================================

CREATE TABLE recurring_schedule_patterns (
    id                      UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id            UUID            NOT NULL REFERENCES institutes(id),
    branch_id               UUID            NOT NULL REFERENCES branches(id),
    patient_id              UUID            NOT NULL REFERENCES patients(id),
    provider_id             UUID            NOT NULL,
    therapy_program_id      UUID            REFERENCES therapy_programs(id),
    therapy_type_id         UUID            NOT NULL REFERENCES therapy_type_registry(id),

    -- Recurrence definition
    frequency               TEXT            NOT NULL,
        -- 'weekly','biweekly','triweekly','custom'
    weekdays                INTEGER[]       NOT NULL,  -- 0=Sunday ... 6=Saturday
    session_start_time      TIME            NOT NULL,
    session_end_time        TIME            NOT NULL,
    modality                TEXT            NOT NULL DEFAULT 'in_person',

    -- Pattern validity window
    pattern_start_date      DATE            NOT NULL,
    pattern_end_date        DATE,           -- NULL = open-ended
    max_sessions            INTEGER,        -- optional session count limit

    -- Generation tracking
    last_generated_date     DATE,
    total_slots_generated   INTEGER         NOT NULL DEFAULT 0,

    is_active               BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by              UUID            REFERENCES users(id),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_rsp_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_rsp_provider_institute
        FOREIGN KEY (provider_id, institute_id)
        REFERENCES user_institute_memberships(user_id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_rsp_time_order
        CHECK (session_end_time > session_start_time),

    CONSTRAINT chk_rsp_date_order
        CHECK (pattern_end_date IS NULL OR pattern_end_date >= pattern_start_date),

    CONSTRAINT chk_rsp_weekdays_valid
        CHECK (weekdays <@ ARRAY[0,1,2,3,4,5,6])
);

-- Add FK from scheduled_slots to recurring_patterns (now that the table exists)
ALTER TABLE scheduled_slots
    ADD CONSTRAINT fk_ss_recurring_pattern
    FOREIGN KEY (recurring_pattern_id)
    REFERENCES recurring_schedule_patterns(id);

CREATE INDEX idx_rsp_institute   ON recurring_schedule_patterns(institute_id);
CREATE INDEX idx_rsp_patient     ON recurring_schedule_patterns(patient_id);
CREATE INDEX idx_rsp_provider    ON recurring_schedule_patterns(provider_id);
CREATE INDEX idx_rsp_program     ON recurring_schedule_patterns(therapy_program_id);
CREATE INDEX idx_rsp_active      ON recurring_schedule_patterns(is_active, pattern_end_date)
    WHERE is_active = TRUE;

ALTER TABLE recurring_schedule_patterns ENABLE ROW LEVEL SECURITY;
ALTER TABLE recurring_schedule_patterns FORCE ROW LEVEL SECURITY;

CREATE POLICY rsp_platform_admin ON recurring_schedule_patterns FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY rsp_read ON recurring_schedule_patterns FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR current_user_assigned_to_patient(patient_id)
         OR provider_id = current_user_id())
);
CREATE POLICY rsp_write ON recurring_schedule_patterns FOR INSERT WITH CHECK (
    institute_id = current_institute_id()
    AND current_user_has_permission('CAN_MANAGE_SESSIONS')
);
CREATE POLICY rsp_update ON recurring_schedule_patterns FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    );

COMMENT ON TABLE recurring_schedule_patterns IS
    'Defines repeating schedule rules. Generates scheduled_slots via application '
    'batch job or trigger on pattern creation. '
    'Pattern changes never mutate historical slots — slots are autonomous after generation. '
    'weekdays: array of 0-6 (Sunday=0). For biweekly, application alternates weeks. '
    'last_generated_date: batch job watermark to avoid duplicate generation.';


-- =============================================================================
-- SECTION 6 — INDEXES ON SCHEDULED_SLOTS
-- =============================================================================

CREATE INDEX idx_ss_institute         ON scheduled_slots(institute_id);
CREATE INDEX idx_ss_patient           ON scheduled_slots(patient_id);
CREATE INDEX idx_ss_provider          ON scheduled_slots(provider_id);
CREATE INDEX idx_ss_program           ON scheduled_slots(therapy_program_id);
CREATE INDEX idx_ss_status            ON scheduled_slots(institute_id, slot_status);
CREATE INDEX idx_ss_scheduled_start   ON scheduled_slots(scheduled_start);
CREATE INDEX idx_ss_provider_date     ON scheduled_slots(provider_id, scheduled_start)
    WHERE slot_status IN ('scheduled','confirmed','checked_in');
CREATE INDEX idx_ss_patient_date      ON scheduled_slots(patient_id, scheduled_start)
    WHERE slot_status IN ('scheduled','confirmed','checked_in');
CREATE INDEX idx_ss_active_branch     ON scheduled_slots(branch_id, scheduled_start)
    WHERE slot_status IN ('scheduled','confirmed','checked_in');
CREATE INDEX idx_ss_converted         ON scheduled_slots(session_id)
    WHERE session_id IS NOT NULL;
CREATE INDEX idx_ss_pattern           ON scheduled_slots(recurring_pattern_id)
    WHERE recurring_pattern_id IS NOT NULL;


-- =============================================================================
-- SECTION 7 — RLS ON SCHEDULED_SLOTS
-- =============================================================================

ALTER TABLE scheduled_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE scheduled_slots FORCE ROW LEVEL SECURITY;

CREATE POLICY ss_platform_admin ON scheduled_slots FOR ALL USING (current_user_is_platform_admin());

CREATE POLICY ss_read ON scheduled_slots FOR SELECT USING (
    institute_id = current_institute_id()
    AND (
        current_user_has_institute_scope()
        OR current_user_assigned_to_patient(patient_id)
        OR provider_id = current_user_id()
    )
);

CREATE POLICY ss_insert ON scheduled_slots FOR INSERT WITH CHECK (
    institute_id = current_institute_id()
    AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    AND current_user_assigned_to_patient(patient_id)
);

-- General update: scheduled/confirmed slots only
CREATE POLICY ss_update ON scheduled_slots FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND slot_status IN ('scheduled','confirmed')
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
        AND (current_user_assigned_to_patient(patient_id) OR provider_id = current_user_id())
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND slot_status IN ('scheduled','confirmed','cancelled','rescheduled')
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
        AND (current_user_assigned_to_patient(patient_id) OR provider_id = current_user_id())
    );

-- Front desk: check-in and conversion
CREATE POLICY ss_checkin ON scheduled_slots FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND slot_status = 'confirmed'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND slot_status IN ('confirmed','checked_in','no_show')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    );

-- Conversion: checked_in → converted (promotion step)
CREATE POLICY ss_convert ON scheduled_slots FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND slot_status = 'checked_in'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND slot_status = 'converted'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    );

-- Delete: only scheduled slots that haven't been confirmed
CREATE POLICY ss_delete ON scheduled_slots FOR DELETE
    USING (
        institute_id = current_institute_id()
        AND slot_status = 'scheduled'
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
        AND current_user_has_institute_scope()
    );


-- =============================================================================
-- SECTION 8 — SCHEDULING ANALYTICS VIEWS
-- =============================================================================

-- Provider utilisation view
CREATE VIEW v_provider_schedule_utilisation AS
SELECT
    ss.institute_id,
    ss.provider_id,
    ss.therapy_type_id,
    DATE_TRUNC('week', ss.scheduled_start) AS week_start,
    COUNT(*) FILTER (WHERE ss.slot_status = 'converted')        AS sessions_completed,
    COUNT(*) FILTER (WHERE ss.slot_status = 'no_show')          AS no_shows,
    COUNT(*) FILTER (WHERE ss.slot_status LIKE 'cancel%')       AS cancellations,
    COUNT(*) FILTER (WHERE ss.slot_status IN ('scheduled','confirmed','checked_in')) AS pending,
    SUM(ss.duration_minutes) FILTER (WHERE ss.slot_status = 'converted') AS total_minutes_delivered
FROM scheduled_slots ss
GROUP BY ss.institute_id, ss.provider_id, ss.therapy_type_id,
         DATE_TRUNC('week', ss.scheduled_start);

-- Patient attendance view
CREATE VIEW v_patient_attendance_summary AS
SELECT
    ss.institute_id,
    ss.patient_id,
    ss.therapy_program_id,
    COUNT(*) FILTER (WHERE ss.slot_status = 'converted')        AS attended,
    COUNT(*) FILTER (WHERE ss.slot_status = 'no_show')          AS no_shows,
    COUNT(*) FILTER (WHERE ss.slot_status LIKE 'cancel%'
        AND cr.responsible_party = 'patient')                   AS patient_cancellations,
    COUNT(*) FILTER (WHERE ss.slot_status LIKE 'cancel%'
        AND cr.responsible_party = 'provider')                  AS provider_cancellations,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE ss.slot_status = 'converted') /
        NULLIF(COUNT(*) FILTER (WHERE ss.slot_status IN (
            'converted','no_show','cancelled')), 0),
        1
    ) AS attendance_rate_pct
FROM scheduled_slots ss
LEFT JOIN cancellation_reason_types cr ON cr.id = ss.cancellation_reason_id
GROUP BY ss.institute_id, ss.patient_id, ss.therapy_program_id;


-- =============================================================================
-- PERMISSIONS SEED — Scheduling
-- =============================================================================

INSERT INTO permissions (code, name, module, description) VALUES
    ('CAN_VIEW_SCHEDULE',       'View Schedule',                'scheduling',
        'View scheduled slots for assigned patients and own schedule'),
    ('CAN_MANAGE_SCHEDULE',     'Manage Schedule',              'scheduling',
        'Create, modify, and cancel scheduled slots'),
    ('CAN_MANAGE_RECURRING',    'Manage Recurring Patterns',    'scheduling',
        'Create and deactivate recurring schedule patterns'),
    ('CAN_CHECKIN_PATIENTS',    'Check In Patients',            'scheduling',
        'Mark patients as checked in and convert slots to session records')
ON CONFLICT (code) DO NOTHING;


-- =============================================================================
-- PHASE 4 SCHEDULING — INVENTORY
-- =============================================================================
--
-- Tables:
--   slot_status_types               (lookup, 7 statuses)
--   cancellation_reason_types       (lookup, 9 reasons)
--   scheduled_slots                 (mutable pre-clinical layer)
--   recurring_schedule_patterns     (pattern definition, generates slots)
--
-- Constraints:
--   excl_provider_no_overlap        EXCLUSION on tstzrange (active slots)
--   excl_patient_no_overlap         EXCLUSION on tstzrange (active slots)
--   uq_ss_session_id                each session from exactly one slot
--
-- Triggers:
--   trg_slot_lifecycle              forward-only status transitions
--   trg_slot_post_conversion_freeze identity facts frozen post-conversion
--   trg_slot_promote_to_session     PROMOTION: checked_in → session_record
--   trg_reschedule_integrity        reschedule chain institute boundary
--
-- Views:
--   v_provider_schedule_utilisation  weekly provider delivery metrics
--   v_patient_attendance_summary     attendance rate per patient per program
--
-- RLS: 6 policies — read, insert, update (general), check-in, conversion, delete
--      All UPDATE policies have WITH CHECK
--
-- =============================================================================
-- NEXT: phase4_billing.sql
-- =============================================================================
-- billing_models, institute_pricing, program_pricing, patient_pricing_contracts
-- billing_charges (immutable, stamped rate), invoices, invoice_line_items
-- payments (append-only), patient_wallets, wallet_transactions
-- insurance_authorizations (auth tracking only)
-- =============================================================================