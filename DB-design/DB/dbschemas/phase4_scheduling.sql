-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 4 — SCHEDULING SUBSYSTEM (CAPACITY-BASED BLOCK MODEL)
-- =============================================================================
-- Replaces: phase4_scheduling.sql draft (1:1 slot model, discarded)
-- Apply after: all Phase 1, 2, and 3 files
-- =============================================================================
--
-- WHY THE 1:1 SLOT MODEL WAS DISCARDED
-- The previous draft assumed 1 slot = 1 patient = 1 provider.
-- This cannot represent:
--   Group therapy    (1 provider → N patients, same clinical goal)
--   Parallel sessions (1 provider → N patients, different individual programs)
--   Co-therapy       (N providers → 1 patient)
--   Shared room occupancy
--
-- BLOCK MODEL (correct):
--   schedule_blocks               → provider time allocation (capacity-aware)
--   schedule_block_providers      → co-therapy provider roster
--   schedule_block_participants   → patient roster (1:N per block)
--   rooms                         → lookup with capacity (enforced Phase 5)
--
-- PROMOTION: per-participant, fires when attendance_status → 'attended' | 'partial'
--   Each attended participant generates exactly one session_record atomically.
--   actual_start = joined_at   ?? block.scheduled_start
--   actual_end   = left_at     ?? block.scheduled_end
--   duration_minutes computed from actual times (clinical documentation only)
--   BILLING: flat per session — duration variance affects docs, not charges.
--
-- CONFLICT DETECTION:
--   Provider: EXCLUSION CONSTRAINT on tstzrange (structural)
--   Patient:  trigger-based overlap check (subquery limitation of EXCLUDE)
--   Capacity: trigger on participant INSERT
-- =============================================================================


-- =============================================================================
-- SECTION 1 — ROOMS (lookup; capacity enforced Phase 5)
-- =============================================================================

CREATE TABLE rooms (
    id              UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id    UUID        NOT NULL REFERENCES institutes(id),
    branch_id       UUID        NOT NULL REFERENCES branches(id),
    name            TEXT        NOT NULL,
    room_type       TEXT        NOT NULL DEFAULT 'therapy_room',
        -- 'therapy_room','assessment_room','group_room','gym','sensory_room','tele_room'
    capacity        INTEGER     NOT NULL DEFAULT 1,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_room_branch_institute
        FOREIGN KEY (branch_id, institute_id)
        REFERENCES branches(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT uq_room_id_institute UNIQUE (id, institute_id),
    CONSTRAINT chk_room_capacity    CHECK (capacity >= 1)
);

COMMENT ON TABLE rooms IS
    'Room lookup for scheduling. Phase 4: room_id on blocks is informational only. '
    'Phase 5 will add EXCLUSION or trigger-based room capacity enforcement. '
    'capacity column stored now to avoid Phase 5 schema change.';

CREATE INDEX idx_rooms_branch   ON rooms(branch_id);
CREATE INDEX idx_rooms_active   ON rooms(institute_id, is_active) WHERE is_active = TRUE;

ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE rooms FORCE ROW LEVEL SECURITY;
CREATE POLICY rooms_platform_admin ON rooms FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY rooms_read  ON rooms FOR SELECT USING (institute_id = current_institute_id());
CREATE POLICY rooms_admin ON rooms FOR ALL USING (
    institute_id = current_institute_id() AND current_user_has_institute_scope()
);


-- =============================================================================
-- SECTION 2 — SCHEDULE BLOCKS (capacity-based time container)
-- =============================================================================

CREATE TABLE schedule_blocks (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    branch_id           UUID            NOT NULL REFERENCES branches(id),
    department_id       UUID            REFERENCES departments(id),
    room_id             UUID            REFERENCES rooms(id),

    -- Primary provider (always required; co-providers in schedule_block_providers)
    primary_provider_id UUID            NOT NULL,

    -- block_type determines participant semantics
    block_type          TEXT            NOT NULL DEFAULT 'individual',
        -- 'individual'  — 1 provider, 1 patient (capacity must = 1)
        -- 'group'       — 1 provider, N patients, shared clinical goal
        -- 'parallel'    — 1 provider, N patients, separate programs
        -- 'co_therapy'  — N providers, 1 patient (capacity must = 1)
        -- 'assessment'  — structured evaluation block

    capacity            INTEGER         NOT NULL DEFAULT 1,

    -- Scheduling
    scheduled_start     TIMESTAMPTZ     NOT NULL,
    scheduled_end       TIMESTAMPTZ     NOT NULL,
    therapy_type_id     UUID            NOT NULL REFERENCES therapy_type_registry(id),
    modality            TEXT            NOT NULL DEFAULT 'in_person',

    -- Block lifecycle
    block_status        TEXT            NOT NULL DEFAULT 'scheduled',
        -- 'scheduled' → 'confirmed' → 'in_progress' → 'completed' | 'cancelled'

    cancellation_notes  TEXT,
    recurring_pattern_id UUID,          -- FK added after recurring_patterns table

    -- Timestamps
    confirmed_at        TIMESTAMPTZ,
    in_progress_at      TIMESTAMPTZ,
    completed_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- ── Composite boundary FKs ────────────────────────────────────────────────
    CONSTRAINT fk_sb_provider_institute
        FOREIGN KEY (primary_provider_id, institute_id)
        REFERENCES user_institute_memberships(user_id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_sb_branch_institute
        FOREIGN KEY (branch_id, institute_id)
        REFERENCES branches(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    -- ── Structural constraints ────────────────────────────────────────────────
    CONSTRAINT chk_sb_time_order        CHECK (scheduled_end > scheduled_start),
    CONSTRAINT chk_sb_capacity_positive CHECK (capacity >= 1),
    CONSTRAINT chk_sb_individual_cap    CHECK (block_type != 'individual'  OR capacity = 1),
    CONSTRAINT chk_sb_cotherapy_cap     CHECK (block_type != 'co_therapy'  OR capacity = 1),
    CONSTRAINT chk_sb_status_valid
        CHECK (block_status IN ('scheduled','confirmed','in_progress','completed','cancelled')),

    -- Timestamp ordering
    CONSTRAINT chk_sb_confirmed_at
        CHECK (confirmed_at IS NULL OR block_status IN ('confirmed','in_progress','completed')),
    CONSTRAINT chk_sb_in_progress_at
        CHECK (in_progress_at IS NULL OR block_status IN ('in_progress','completed')),
    CONSTRAINT chk_sb_completed_at
        CHECK (completed_at IS NULL OR block_status = 'completed'),

    CONSTRAINT uq_sb_id_institute UNIQUE (id, institute_id)
);

COMMENT ON TABLE schedule_blocks IS
    'Provider time allocation container — the pre-clinical mutable scheduling layer. '
    'block_type + capacity determine participant semantics: '
    '  individual: capacity=1, standard 1:1 session. '
    '  group: capacity>1, N patients same clinical goal (social skills, group ABA). '
    '  parallel: capacity>1, N patients different programs (provider manages separately). '
    '  co_therapy: capacity=1, multiple providers via schedule_block_providers. '
    '  assessment: capacity flexible, evaluation context. '
    'Promotion: per-participant when attendance_status→attended. '
    'One session_record created per attending patient atomically.';

-- Indexes
CREATE INDEX idx_sb_institute         ON schedule_blocks(institute_id);
CREATE INDEX idx_sb_provider          ON schedule_blocks(primary_provider_id);
CREATE INDEX idx_sb_status            ON schedule_blocks(institute_id, block_status);
CREATE INDEX idx_sb_start             ON schedule_blocks(scheduled_start);
CREATE INDEX idx_sb_active_provider   ON schedule_blocks(primary_provider_id, scheduled_start)
    WHERE block_status IN ('scheduled','confirmed','in_progress');
CREATE INDEX idx_sb_branch_active     ON schedule_blocks(branch_id, scheduled_start)
    WHERE block_status IN ('scheduled','confirmed','in_progress');


-- =============================================================================
-- SECTION 3 — CO-THERAPY PROVIDER ROSTER
-- =============================================================================

CREATE TABLE schedule_block_providers (
    id                  UUID        PRIMARY KEY DEFAULT generate_uuidv7(),
    schedule_block_id   UUID        NOT NULL REFERENCES schedule_blocks(id),
    institute_id        UUID        NOT NULL REFERENCES institutes(id),
    provider_id         UUID        NOT NULL,
    role                TEXT        NOT NULL DEFAULT 'co_therapist',
        -- 'co_therapist','supervisor','student_observer','interpreter'
    added_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    added_by            UUID        REFERENCES users(id),

    CONSTRAINT uq_sbp_block_provider UNIQUE (schedule_block_id, provider_id),

    CONSTRAINT fk_sbp_provider_institute
        FOREIGN KEY (provider_id, institute_id)
        REFERENCES user_institute_memberships(user_id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_sbp_block_institute
        FOREIGN KEY (schedule_block_id, institute_id)
        REFERENCES schedule_blocks(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED
);

-- Co-provider must not be the primary provider
CREATE OR REPLACE FUNCTION enforce_sbp_not_primary()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_primary UUID;
BEGIN
    SELECT primary_provider_id INTO v_primary FROM schedule_blocks WHERE id = NEW.schedule_block_id;
    IF v_primary = NEW.provider_id THEN
        RAISE EXCEPTION 'Provider % is already the primary_provider of block %. '
            'Primary provider does not need a co-provider row.', NEW.provider_id, NEW.schedule_block_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sbp_not_primary
    BEFORE INSERT ON schedule_block_providers
    FOR EACH ROW EXECUTE FUNCTION enforce_sbp_not_primary();

-- Roster frozen on completed blocks
CREATE OR REPLACE FUNCTION enforce_sbp_completed_freeze()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_status TEXT;
BEGIN
    SELECT block_status INTO v_status FROM schedule_blocks WHERE id = OLD.schedule_block_id;
    IF v_status = 'completed' THEN
        RAISE EXCEPTION 'schedule_block % is completed — co-provider roster is frozen.', OLD.schedule_block_id;
    END IF;
    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_sbp_completed_freeze
    BEFORE DELETE ON schedule_block_providers
    FOR EACH ROW EXECUTE FUNCTION enforce_sbp_completed_freeze();

CREATE INDEX idx_sbp_block    ON schedule_block_providers(schedule_block_id);
CREATE INDEX idx_sbp_provider ON schedule_block_providers(provider_id);

ALTER TABLE schedule_block_providers ENABLE ROW LEVEL SECURITY;
ALTER TABLE schedule_block_providers FORCE ROW LEVEL SECURITY;
CREATE POLICY sbp_platform_admin ON schedule_block_providers FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY sbp_read ON schedule_block_providers FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR provider_id = current_user_id())
);
CREATE POLICY sbp_write ON schedule_block_providers FOR INSERT WITH CHECK (
    institute_id = current_institute_id() AND current_user_has_permission('CAN_MANAGE_SESSIONS')
);


-- =============================================================================
-- SECTION 4 — CONFLICT DETECTION
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Provider double-booking: structural EXCLUSION CONSTRAINT
ALTER TABLE schedule_blocks
    ADD CONSTRAINT excl_provider_no_overlap
    EXCLUDE USING gist (
        institute_id            WITH =,
        primary_provider_id     WITH =,
        tstzrange(scheduled_start, scheduled_end, '[)') WITH &&
    )
    WHERE (block_status IN ('scheduled','confirmed','in_progress'));

COMMENT ON CONSTRAINT excl_provider_no_overlap ON schedule_blocks IS
    'Structural: primary provider cannot have overlapping active blocks in same institute. '
    'Half-open [start,end): back-to-back blocks permitted. '
    'Co-provider conflicts: application responsibility (Phase 5 may add structural check).';


-- =============================================================================
-- SECTION 5 — BLOCK PARTICIPANTS (patient roster + promotion anchor)
-- =============================================================================

CREATE TABLE schedule_block_participants (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    schedule_block_id   UUID            NOT NULL REFERENCES schedule_blocks(id),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    patient_id          UUID            NOT NULL REFERENCES patients(id),
    therapy_program_id  UUID            REFERENCES therapy_programs(id),
    therapy_type_id     UUID            REFERENCES therapy_type_registry(id),
        -- NULL: inherits from block (shared type in group sessions)

    -- Attendance
    attendance_status   TEXT            NOT NULL DEFAULT 'scheduled',
        -- 'scheduled' → 'attended' | 'partial' | 'no_show' | 'cancelled'
    joined_at           TIMESTAMPTZ,
    left_at             TIMESTAMPTZ,
    attendance_notes    TEXT,

    -- Promotion result
    session_id          UUID            REFERENCES session_records(id),
    promoted_at         TIMESTAMPTZ,

    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            REFERENCES users(id),

    CONSTRAINT uq_sbpart_block_patient  UNIQUE (schedule_block_id, patient_id),
    CONSTRAINT uq_sbpart_session_id     UNIQUE (session_id),  -- structural double-promotion backstop

    CONSTRAINT fk_sbpart_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_sbpart_block_institute
        FOREIGN KEY (schedule_block_id, institute_id)
        REFERENCES schedule_blocks(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_sbpart_program_institute
        FOREIGN KEY (therapy_program_id, institute_id)
        REFERENCES therapy_programs(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_sbpart_status_valid
        CHECK (attendance_status IN ('scheduled','attended','partial','no_show','cancelled')),

    CONSTRAINT chk_sbpart_session_when_attended
        CHECK (attendance_status IN ('attended','partial') OR session_id IS NULL),

    CONSTRAINT chk_sbpart_attended_requires_session
        CHECK (attendance_status NOT IN ('attended','partial') OR session_id IS NOT NULL),

    CONSTRAINT chk_sbpart_joined_before_left
        CHECK (joined_at IS NULL OR left_at IS NULL OR left_at >= joined_at),

    CONSTRAINT chk_sbpart_promoted_at_timing
        CHECK (promoted_at IS NULL OR session_id IS NOT NULL)
);

COMMENT ON TABLE schedule_block_participants IS
    'Patient roster per block. Promotion anchor row. '
    'attendance_status → attended|partial fires per-participant session_record creation. '
    'joined_at/left_at track actual attendance window — '
    '  actual_start/end on resulting session_record derived from these. '
    'BILLING NOTE: charges are flat per session — duration_minutes on session_record '
    '  is clinical documentation only, not billing input. '
    'uq_sbpart_session_id: structural backstop preventing double-promotion.';

-- Patient double-booking prevention (trigger, cannot use EXCLUDE with subquery)
CREATE OR REPLACE FUNCTION enforce_patient_block_no_overlap()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_new_start  TIMESTAMPTZ;
    v_new_end    TIMESTAMPTZ;
    v_conflict   UUID;
BEGIN
    SELECT scheduled_start, scheduled_end INTO v_new_start, v_new_end
    FROM schedule_blocks WHERE id = NEW.schedule_block_id;

    SELECT sbp.id INTO v_conflict
    FROM schedule_block_participants sbp
    JOIN schedule_blocks sb ON sb.id = sbp.schedule_block_id
    WHERE sbp.patient_id         = NEW.patient_id
      AND sbp.institute_id       = NEW.institute_id
      AND sbp.id                != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID)
      AND sbp.attendance_status NOT IN ('no_show','cancelled')
      AND sb.block_status        NOT IN ('cancelled','completed')
      AND tstzrange(sb.scheduled_start, sb.scheduled_end, '[)')
          && tstzrange(v_new_start, v_new_end, '[)')
    LIMIT 1;

    IF v_conflict IS NOT NULL THEN
        RAISE EXCEPTION
            'Patient % already has an overlapping active block (participant row %). '
            'A patient cannot be in two overlapping active blocks.',
            NEW.patient_id, v_conflict;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_patient_no_overlap
    BEFORE INSERT OR UPDATE OF patient_id, schedule_block_id, attendance_status
    ON schedule_block_participants
    FOR EACH ROW EXECUTE FUNCTION enforce_patient_block_no_overlap();

-- Capacity enforcement
CREATE OR REPLACE FUNCTION enforce_block_capacity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_capacity  INTEGER;
    v_count     INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM schedule_blocks WHERE id = NEW.schedule_block_id;

    SELECT COUNT(*) INTO v_count
    FROM schedule_block_participants
    WHERE schedule_block_id = NEW.schedule_block_id
      AND attendance_status != 'cancelled'
      AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID);

    IF v_count >= v_capacity THEN
        RAISE EXCEPTION
            'schedule_block % is at capacity (%). Cannot add more participants.',
            NEW.schedule_block_id, v_capacity;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_block_capacity
    BEFORE INSERT ON schedule_block_participants
    FOR EACH ROW EXECUTE FUNCTION enforce_block_capacity();

-- Post-promotion freeze
CREATE OR REPLACE FUNCTION enforce_participant_post_promotion_freeze()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.session_id IS NOT NULL THEN
        IF NEW.patient_id         IS DISTINCT FROM OLD.patient_id        OR
           NEW.schedule_block_id  IS DISTINCT FROM OLD.schedule_block_id OR
           NEW.therapy_program_id IS DISTINCT FROM OLD.therapy_program_id OR
           NEW.session_id         IS DISTINCT FROM OLD.session_id
        THEN
            RAISE EXCEPTION
                'schedule_block_participant % is promoted to session %. '
                'patient, block, program, and session_id are frozen post-promotion.',
                OLD.id, OLD.session_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_participant_post_promotion_freeze
    BEFORE UPDATE ON schedule_block_participants
    FOR EACH ROW EXECUTE FUNCTION enforce_participant_post_promotion_freeze();

CREATE INDEX idx_sbpart_block     ON schedule_block_participants(schedule_block_id);
CREATE INDEX idx_sbpart_patient   ON schedule_block_participants(patient_id);
CREATE INDEX idx_sbpart_session   ON schedule_block_participants(session_id)   WHERE session_id IS NOT NULL;
CREATE INDEX idx_sbpart_institute ON schedule_block_participants(institute_id);
CREATE INDEX idx_sbpart_status    ON schedule_block_participants(schedule_block_id, attendance_status);


-- =============================================================================
-- SECTION 6 — BLOCK LIFECYCLE TRIGGERS
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_block_lifecycle()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.block_status = OLD.block_status THEN RETURN NEW; END IF;

    IF OLD.block_status = 'scheduled'   AND NEW.block_status NOT IN ('scheduled','confirmed','cancelled') THEN
        RAISE EXCEPTION 'block %: invalid transition scheduled → %. Permitted: confirmed, cancelled.', OLD.id, NEW.block_status;
    END IF;
    IF OLD.block_status = 'confirmed'   AND NEW.block_status NOT IN ('confirmed','in_progress','cancelled') THEN
        RAISE EXCEPTION 'block %: invalid transition confirmed → %. Permitted: in_progress, cancelled.', OLD.id, NEW.block_status;
    END IF;
    IF OLD.block_status = 'in_progress' AND NEW.block_status NOT IN ('in_progress','completed') THEN
        RAISE EXCEPTION 'block %: invalid transition in_progress → %. Only completed permitted.', OLD.id, NEW.block_status;
    END IF;
    IF OLD.block_status IN ('completed','cancelled') THEN
        RAISE EXCEPTION 'block %: status=% is terminal.', OLD.id, OLD.block_status;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_block_lifecycle
    BEFORE UPDATE OF block_status ON schedule_blocks
    FOR EACH ROW EXECUTE FUNCTION enforce_block_lifecycle();

-- Identity freeze at completion
CREATE OR REPLACE FUNCTION enforce_block_completed_freeze()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.block_status = 'completed' THEN
        IF NEW.primary_provider_id IS DISTINCT FROM OLD.primary_provider_id OR
           NEW.institute_id        != OLD.institute_id                        OR
           NEW.branch_id           IS DISTINCT FROM OLD.branch_id             OR
           NEW.scheduled_start     != OLD.scheduled_start                     OR
           NEW.scheduled_end       != OLD.scheduled_end                       OR
           NEW.block_type          != OLD.block_type                          OR
           NEW.therapy_type_id     IS DISTINCT FROM OLD.therapy_type_id
        THEN
            RAISE EXCEPTION 'block % is completed — identity and time facts are frozen.', OLD.id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_block_completed_freeze
    BEFORE UPDATE ON schedule_blocks
    FOR EACH ROW EXECUTE FUNCTION enforce_block_completed_freeze();


-- =============================================================================
-- SECTION 7 — PER-PARTICIPANT PROMOTION (THE CRITICAL TRIGGER)
-- =============================================================================

CREATE OR REPLACE FUNCTION promote_participant_to_session()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_session_id        UUID;
    v_block             schedule_blocks%ROWTYPE;
    v_therapy_type_id   UUID;
    v_actual_start      TIMESTAMPTZ;
    v_actual_end        TIMESTAMPTZ;
BEGIN
    -- Only fire on transition INTO attended/partial from a non-attended state
    IF NEW.attendance_status NOT IN ('attended','partial')    THEN RETURN NEW; END IF;
    IF OLD.attendance_status IN ('attended','partial')        THEN RETURN NEW; END IF;

    -- Guard against double-promotion
    IF OLD.session_id IS NOT NULL THEN
        RAISE EXCEPTION 'Participant % already promoted to session %. Double promotion blocked.',
            OLD.id, OLD.session_id;
    END IF;

    SELECT * INTO v_block FROM schedule_blocks WHERE id = NEW.schedule_block_id;

    IF v_block.block_status NOT IN ('confirmed','in_progress') THEN
        RAISE EXCEPTION 'Block % status=% — must be confirmed or in_progress for promotion.',
            NEW.schedule_block_id, v_block.block_status;
    END IF;

    -- Resolve therapy_type (participant-level overrides block)
    v_therapy_type_id := COALESCE(NEW.therapy_type_id, v_block.therapy_type_id);

    -- Resolve actual times (joined/left override block times)
    v_actual_start := COALESCE(NEW.joined_at, v_block.scheduled_start);
    v_actual_end   := COALESCE(NEW.left_at,   v_block.scheduled_end);

    v_session_id := generate_uuidv7();

    INSERT INTO session_records (
        id, institute_id, branch_id, department_id,
        patient_id, provider_id,
        therapy_program_id, therapy_type_id,
        scheduled_start, scheduled_end,
        actual_start, actual_end,
        duration_minutes,
        modality, attendance_status,
        status, note_status, created_by
    ) VALUES (
        v_session_id,
        v_block.institute_id, v_block.branch_id, v_block.department_id,
        NEW.patient_id, v_block.primary_provider_id,
        NEW.therapy_program_id, v_therapy_type_id,
        v_block.scheduled_start, v_block.scheduled_end,
        v_actual_start, v_actual_end,
        GREATEST(1, ROUND(EXTRACT(EPOCH FROM (v_actual_end - v_actual_start)) / 60)),
        v_block.modality, 'attended',
        'in_progress', 'draft',
        NEW.created_by
    );

    NEW.session_id  := v_session_id;
    NEW.promoted_at := NOW();

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_participant_promote
    BEFORE UPDATE OF attendance_status ON schedule_block_participants
    FOR EACH ROW EXECUTE FUNCTION promote_participant_to_session();

COMMENT ON TRIGGER trg_participant_promote ON schedule_block_participants IS
    'PER-PARTICIPANT PROMOTION. Fires: attendance_status → attended|partial. '
    'Creates one session_record per participant atomically. '
    'actual_start = joined_at ?? block.scheduled_start. '
    'actual_end   = left_at   ?? block.scheduled_end. '
    'duration_minutes = clinical documentation. Billing is flat per session. '
    'Group of 5 → 5 independent session_records, each billed individually. '
    'uq_sbpart_session_id is structural backstop against double-promotion.';


-- =============================================================================
-- SECTION 8 — RECURRING PATTERNS (generates blocks)
-- =============================================================================

CREATE TABLE recurring_schedule_patterns (
    id                      UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id            UUID            NOT NULL REFERENCES institutes(id),
    branch_id               UUID            NOT NULL REFERENCES branches(id),
    primary_provider_id     UUID            NOT NULL,
    therapy_type_id         UUID            NOT NULL REFERENCES therapy_type_registry(id),

    -- Default patient for individual patterns; NULL for group patterns
    default_patient_id          UUID        REFERENCES patients(id),
    default_therapy_program_id  UUID        REFERENCES therapy_programs(id),

    -- Block defaults
    block_type              TEXT            NOT NULL DEFAULT 'individual',
    default_capacity        INTEGER         NOT NULL DEFAULT 1,
    modality                TEXT            NOT NULL DEFAULT 'in_person',
    room_id                 UUID            REFERENCES rooms(id),

    -- Recurrence
    frequency               TEXT            NOT NULL,
        -- 'weekly','biweekly','triweekly','custom'
    weekdays                INTEGER[]       NOT NULL,
    session_start_time      TIME            NOT NULL,
    session_end_time        TIME            NOT NULL,

    -- Validity
    pattern_start_date      DATE            NOT NULL,
    pattern_end_date        DATE,
    max_blocks              INTEGER,

    -- Generation watermark
    last_generated_date     DATE,
    total_blocks_generated  INTEGER         NOT NULL DEFAULT 0,

    is_active               BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by              UUID            REFERENCES users(id),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_rsp_provider_institute
        FOREIGN KEY (primary_provider_id, institute_id)
        REFERENCES user_institute_memberships(user_id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_rsp_time_order    CHECK (session_end_time > session_start_time),
    CONSTRAINT chk_rsp_date_order    CHECK (pattern_end_date IS NULL OR pattern_end_date >= pattern_start_date),
    CONSTRAINT chk_rsp_weekdays      CHECK (weekdays <@ ARRAY[0,1,2,3,4,5,6]),
    CONSTRAINT chk_rsp_capacity      CHECK (default_capacity >= 1)
);

ALTER TABLE schedule_blocks
    ADD CONSTRAINT fk_sb_recurring_pattern
    FOREIGN KEY (recurring_pattern_id) REFERENCES recurring_schedule_patterns(id);

CREATE INDEX idx_rsp_institute ON recurring_schedule_patterns(institute_id);
CREATE INDEX idx_rsp_provider  ON recurring_schedule_patterns(primary_provider_id);
CREATE INDEX idx_rsp_patient   ON recurring_schedule_patterns(default_patient_id) WHERE default_patient_id IS NOT NULL;
CREATE INDEX idx_rsp_active    ON recurring_schedule_patterns(institute_id, is_active) WHERE is_active = TRUE;

ALTER TABLE recurring_schedule_patterns ENABLE ROW LEVEL SECURITY;
ALTER TABLE recurring_schedule_patterns FORCE ROW LEVEL SECURITY;
CREATE POLICY rsp_platform_admin ON recurring_schedule_patterns FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY rsp_read ON recurring_schedule_patterns FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR primary_provider_id = current_user_id()
         OR (default_patient_id IS NOT NULL AND current_user_assigned_to_patient(default_patient_id)))
);
CREATE POLICY rsp_write ON recurring_schedule_patterns FOR INSERT WITH CHECK (
    institute_id = current_institute_id() AND current_user_has_permission('CAN_MANAGE_SESSIONS')
);
CREATE POLICY rsp_update ON recurring_schedule_patterns FOR UPDATE
    USING  (institute_id = current_institute_id() AND current_user_has_permission('CAN_MANAGE_SESSIONS'))
    WITH CHECK (institute_id = current_institute_id() AND current_user_has_permission('CAN_MANAGE_SESSIONS'));


-- =============================================================================
-- SECTION 9 — RLS ON CORE TABLES
-- =============================================================================

ALTER TABLE schedule_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE schedule_blocks FORCE ROW LEVEL SECURITY;

CREATE POLICY sb_platform_admin ON schedule_blocks FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY sb_read ON schedule_blocks FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR primary_provider_id = current_user_id()
         OR EXISTS (
             SELECT 1 FROM schedule_block_participants p
             WHERE p.schedule_block_id = schedule_blocks.id
               AND current_user_assigned_to_patient(p.patient_id)
         ))
);
CREATE POLICY sb_insert ON schedule_blocks FOR INSERT WITH CHECK (
    institute_id = current_institute_id()
    AND current_user_has_permission('CAN_MANAGE_SESSIONS')
);
CREATE POLICY sb_update ON schedule_blocks FOR UPDATE
    USING  (
        institute_id = current_institute_id()
        AND block_status IN ('scheduled','confirmed')
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND block_status IN ('scheduled','confirmed','cancelled')
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    );
CREATE POLICY sb_progress ON schedule_blocks FOR UPDATE
    USING  (
        institute_id = current_institute_id()
        AND block_status IN ('confirmed','in_progress')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND block_status IN ('confirmed','in_progress','completed')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    );

ALTER TABLE schedule_block_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE schedule_block_participants FORCE ROW LEVEL SECURITY;

CREATE POLICY sbpart_platform_admin ON schedule_block_participants FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY sbpart_read ON schedule_block_participants FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR current_user_assigned_to_patient(patient_id))
);
CREATE POLICY sbpart_insert ON schedule_block_participants FOR INSERT WITH CHECK (
    institute_id = current_institute_id() AND current_user_has_permission('CAN_MANAGE_SESSIONS')
);
CREATE POLICY sbpart_attendance ON schedule_block_participants FOR UPDATE
    USING  (
        institute_id = current_institute_id()
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND attendance_status IN ('scheduled','attended','partial','no_show','cancelled')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    );


-- =============================================================================
-- SECTION 10 — ANALYTICS VIEWS
-- =============================================================================

CREATE VIEW v_provider_block_utilisation AS
SELECT
    sb.institute_id, sb.primary_provider_id, sb.therapy_type_id, sb.block_type,
    DATE_TRUNC('week', sb.scheduled_start)                              AS week_start,
    COUNT(DISTINCT sb.id)                                               AS total_blocks,
    COUNT(DISTINCT sb.id) FILTER (WHERE sb.block_status = 'completed') AS completed,
    COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'attended')    AS patients_attended,
    COUNT(sbp.id) FILTER (WHERE sbp.attendance_status = 'no_show')     AS no_shows,
    SUM(EXTRACT(EPOCH FROM (sb.scheduled_end - sb.scheduled_start))/60)
        FILTER (WHERE sb.block_status = 'completed')                    AS scheduled_minutes
FROM schedule_blocks sb
LEFT JOIN schedule_block_participants sbp ON sbp.schedule_block_id = sb.id
GROUP BY sb.institute_id, sb.primary_provider_id, sb.therapy_type_id,
         sb.block_type, DATE_TRUNC('week', sb.scheduled_start);

CREATE VIEW v_patient_attendance AS
SELECT
    sbp.institute_id, sbp.patient_id, sbp.therapy_program_id, sb.block_type,
    COUNT(*)                                                            AS total_scheduled,
    COUNT(*) FILTER (WHERE sbp.attendance_status = 'attended')         AS attended,
    COUNT(*) FILTER (WHERE sbp.attendance_status = 'no_show')          AS no_shows,
    COUNT(*) FILTER (WHERE sbp.attendance_status = 'cancelled')        AS cancelled,
    ROUND(100.0 * COUNT(*) FILTER (WHERE sbp.attendance_status = 'attended') /
        NULLIF(COUNT(*) FILTER (
            WHERE sbp.attendance_status IN ('attended','no_show','cancelled')), 0), 1
    )                                                                   AS attendance_pct
FROM schedule_block_participants sbp
JOIN schedule_blocks sb ON sb.id = sbp.schedule_block_id
GROUP BY sbp.institute_id, sbp.patient_id, sbp.therapy_program_id, sb.block_type;


-- =============================================================================
-- PERMISSIONS
-- =============================================================================
INSERT INTO permissions (code, name, module, description) VALUES
    ('CAN_VIEW_SCHEDULE',    'View Schedule',            'scheduling', 'View blocks and own schedule'),
    ('CAN_MANAGE_SESSIONS',  'Manage Blocks/Sessions',   'scheduling', 'Create and manage schedule blocks'),
    ('CAN_MANAGE_RECURRING', 'Manage Recurring Patterns','scheduling', 'Create/deactivate recurring patterns'),
    ('CAN_CHECKIN_PATIENTS', 'Check In Patients',        'scheduling', 'Mark attendance and trigger promotion')
ON CONFLICT (code) DO NOTHING;


-- =============================================================================
-- PHASE 4 SCHEDULING — FINAL INVENTORY
-- =============================================================================
--
-- Tables:        rooms, schedule_blocks, schedule_block_providers,
--                schedule_block_participants, recurring_schedule_patterns
--
-- Conflict:      excl_provider_no_overlap (EXCLUSION, structural)
--                trg_patient_no_overlap (trigger, patient double-booking)
--                trg_block_capacity (trigger, capacity enforcement)
--
-- Promotion:     trg_participant_promote (per-participant → session_record)
--                uq_sbpart_session_id (double-promotion backstop)
--
-- Freeze:        trg_block_lifecycle (forward-only transitions)
--                trg_block_completed_freeze (identity frozen at completed)
--                trg_participant_post_promotion_freeze (frozen post-promotion)
--                trg_sbp_not_primary / trg_sbp_completed_freeze
--
-- RLS:           All UPDATE policies include WITH CHECK
--
-- Block types:   individual, group, parallel, co_therapy, assessment
--
-- NEXT: phase4_billing.sql
-- =============================================================================
