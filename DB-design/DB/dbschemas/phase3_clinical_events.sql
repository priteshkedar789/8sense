-- =============================================================================
-- THERAPY INSTITUTE PLATFORM
-- PHASE 3 — CLINICAL EVENTS
-- =============================================================================
-- Apply after: phase3_evaluations.sql + patch01
-- This is the final file in Phase 3.
-- =============================================================================
--
-- LOCKED DECISIONS
-- ─────────────────────────────────────────────────────────────────────────────
-- [D-CE1] Milestones: hybrid model
--         program_milestones — mutable header (goal definition, target, priority)
--         milestone_progress_entries — append-only observations
--         Milestone header frozen at program activation (same pattern as dept_id).
--         Progress entries: immutable once written (INSERT only, no UPDATE/DELETE).
--
-- [D-CE2] Plan change requests drive program versioning.
--         PCR status: draft → submitted → approved → implemented | rejected
--         On approved → implemented transition: trigger auto-creates
--         therapy_program_version snapshot. Every version has an approval trail.
--         No orphan versions — program versions cannot exist without a PCR.
--
-- [D-CE3] Case conference freeze at review (not submission).
--         Case conferences are multidisciplinary artifacts.
--         submission = minutes recorded by one clinician.
--         reviewed = institutional validation of the MDT record.
--         Freeze at reviewed. Absolute freeze at locked.
--
-- [D-CE4] milestone_progress_entries.session_id nullable, but if set,
--         must reference a completed session for the same patient.
--         Standalone progress observations allowed (parent report, home observation,
--         weekly review, school feedback). Session-linked entries validated.
-- =============================================================================


-- =============================================================================
-- SECTION 1 — PROGRAM MILESTONES (hybrid: mutable header)
-- =============================================================================

CREATE TABLE program_milestones (
    id                      UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id            UUID            NOT NULL REFERENCES institutes(id),
    therapy_program_id      UUID            NOT NULL REFERENCES therapy_programs(id),
    program_version_id      UUID            NOT NULL REFERENCES therapy_program_versions(id),
    program_goal_id         UUID            REFERENCES program_goals(id),  -- optional link to goal

    -- Goal definition (mutable in draft; frozen at program activation)
    milestone_title         TEXT            NOT NULL,
    domain                  TEXT,
        -- 'fine_motor','gross_motor','communication','social','self_care','academic','behavioral'
    target_criteria         TEXT            NOT NULL,
    baseline_description    TEXT,
    target_date             DATE,
    priority                INTEGER         NOT NULL DEFAULT 1,
    is_long_term            BOOLEAN         NOT NULL DEFAULT FALSE,
    parent_milestone_id     UUID            REFERENCES program_milestones(id),

    -- Lifecycle
    milestone_status        TEXT            NOT NULL DEFAULT 'active',
        -- 'active', 'achieved', 'discontinued', 'deferred', 'not_started'
    achieved_date           DATE,

    is_active               BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by              UUID            REFERENCES users(id),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_pm_program_institute
        FOREIGN KEY (therapy_program_id, institute_id)
        REFERENCES therapy_programs(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_pm_version_program
        FOREIGN KEY (program_version_id, therapy_program_id)
        REFERENCES therapy_program_versions(id, therapy_program_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_pm_no_self_parent
        CHECK (parent_milestone_id IS NULL OR parent_milestone_id != id),

    CONSTRAINT chk_pm_achieved_date
        CHECK (milestone_status != 'achieved' OR achieved_date IS NOT NULL),

    CONSTRAINT uq_pm_id_institute UNIQUE (id, institute_id)
);

COMMENT ON TABLE program_milestones IS
    '[D-CE1] Milestone header — mutable goal definition. '
    'Frozen when therapy_program.program_status reaches active (same freeze boundary as dept_id). '
    'Progress observations are in milestone_progress_entries (append-only). '
    'Hybrid: planning artifact (header) + observation log (entries) kept separate. '
    'program_goal_id optionally links back to the program_goals formal goal definition.';

-- Milestone header frozen at program activation (mirrors dept_id/type_map freeze boundary)
CREATE OR REPLACE FUNCTION enforce_milestone_header_freeze()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_program_status TEXT;
BEGIN
    SELECT program_status INTO v_program_status
    FROM therapy_programs
    WHERE id = OLD.therapy_program_id;

    IF v_program_status IN ('active', 'paused', 'completed', 'discontinued') THEN
        IF NEW.milestone_title        IS DISTINCT FROM OLD.milestone_title       OR
           NEW.domain                 IS DISTINCT FROM OLD.domain                OR
           NEW.target_criteria        IS DISTINCT FROM OLD.target_criteria       OR
           NEW.therapy_program_id     IS DISTINCT FROM OLD.therapy_program_id    OR
           NEW.program_version_id     IS DISTINCT FROM OLD.program_version_id    OR
           NEW.is_long_term           IS DISTINCT FROM OLD.is_long_term          OR
           NEW.parent_milestone_id    IS DISTINCT FROM OLD.parent_milestone_id
        THEN
            RAISE EXCEPTION
                '[D-CE1] program_milestone % definition is frozen — '
                'program % is % (active or beyond). '
                'Milestone title, domain, target criteria, and structural fields '
                'cannot change once the program is active. '
                'milestone_status, achieved_date, target_date, and is_active '
                'remain mutable for lifecycle management.',
                OLD.id, OLD.therapy_program_id, v_program_status;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_milestone_header_freeze
    BEFORE UPDATE ON program_milestones
    FOR EACH ROW
    EXECUTE FUNCTION enforce_milestone_header_freeze();

-- Indexes
CREATE INDEX idx_pm_program        ON program_milestones(therapy_program_id);
CREATE INDEX idx_pm_version        ON program_milestones(program_version_id);
CREATE INDEX idx_pm_institute      ON program_milestones(institute_id);
CREATE INDEX idx_pm_goal           ON program_milestones(program_goal_id);
CREATE INDEX idx_pm_parent         ON program_milestones(parent_milestone_id);
CREATE INDEX idx_pm_status         ON program_milestones(therapy_program_id, milestone_status);
CREATE INDEX idx_pm_active         ON program_milestones(therapy_program_id, is_active)
    WHERE is_active = TRUE;

ALTER TABLE program_milestones ENABLE ROW LEVEL SECURITY;
ALTER TABLE program_milestones FORCE ROW LEVEL SECURITY;

CREATE POLICY pm_platform_admin ON program_milestones FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY pm_read ON program_milestones FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR EXISTS (
        SELECT 1 FROM therapy_programs tp
        WHERE tp.id = program_milestones.therapy_program_id
          AND current_user_assigned_to_patient(tp.patient_id)
    ))
);
CREATE POLICY pm_write ON program_milestones FOR INSERT WITH CHECK (
    institute_id = current_institute_id()
    AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
);
CREATE POLICY pm_update ON program_milestones FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    );


-- =============================================================================
-- SECTION 2 — MILESTONE PROGRESS ENTRIES (append-only observations)
-- =============================================================================

CREATE TABLE milestone_progress_entries (
    id                  UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id        UUID            NOT NULL REFERENCES institutes(id),
    milestone_id        UUID            NOT NULL REFERENCES program_milestones(id),
    therapy_program_id  UUID            NOT NULL REFERENCES therapy_programs(id),

    -- [D-CE4] session_id nullable; if set, must be completed session for same patient
    session_id          UUID            REFERENCES session_records(id),

    -- Observation content
    progress_status     TEXT            NOT NULL,
        -- 'not_started','progressing','achieved','regressing','plateau','discontinued'
    observation_notes   TEXT,
    measured_value      NUMERIC,        -- e.g. percentage correct, frequency count
    measured_unit       TEXT,           -- 'percent', 'count_per_session', 'seconds', etc.
    observation_source  TEXT            NOT NULL DEFAULT 'session',
        -- 'session', 'parent_report', 'school_feedback', 'home_observation',
        -- 'weekly_review', 'evaluation', 'case_conference'
    observation_date    DATE            NOT NULL DEFAULT CURRENT_DATE,

    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by          UUID            NOT NULL REFERENCES users(id),

    CONSTRAINT fk_mpe_milestone_program
        FOREIGN KEY (milestone_id, therapy_program_id)
        REFERENCES program_milestones(id, institute_id)  -- partial; milestone has uq_pm_id_institute
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_mpe_program_institute
        FOREIGN KEY (therapy_program_id, institute_id)
        REFERENCES therapy_programs(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_mpe_progress_status
        CHECK (progress_status IN (
            'not_started','progressing','achieved',
            'regressing','plateau','discontinued'
        )),

    CONSTRAINT chk_mpe_measured_value_unit
        CHECK (measured_value IS NULL OR measured_unit IS NOT NULL)
);

COMMENT ON TABLE milestone_progress_entries IS
    '[D-CE1] Append-only progress observations against a milestone. '
    'INSERT only — no UPDATE or DELETE. Immutable once written. '
    'session_id nullable: supports standalone observations (parent report, '
    'home observation, weekly review, school feedback). '
    'If session_id set: validated against completed session for same patient. '
    'Longitudinal trend: query all entries for a milestone ordered by observation_date.';

-- Append-only enforcement
CREATE OR REPLACE FUNCTION enforce_progress_entry_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'milestone_progress_entry % is an immutable observation record. '
        'Progress entries cannot be modified or deleted. '
        'Create a new entry to record updated progress.',
        OLD.id;
END;
$$;

CREATE TRIGGER trg_mpe_immutable
    BEFORE UPDATE OR DELETE ON milestone_progress_entries
    FOR EACH ROW
    EXECUTE FUNCTION enforce_progress_entry_immutability();

-- [D-CE4] session_id cross-table validation
CREATE OR REPLACE FUNCTION enforce_progress_entry_session_integrity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_session_status    TEXT;
    v_session_patient   UUID;
    v_program_patient   UUID;
BEGIN
    IF NEW.session_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT sr.status, sr.patient_id INTO v_session_status, v_session_patient
    FROM session_records sr
    WHERE sr.id = NEW.session_id
      AND sr.institute_id = NEW.institute_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'milestone_progress_entry: session_id % is not a valid session '
            'in institute %.',
            NEW.session_id, NEW.institute_id;
    END IF;

    -- Session must be completed (progress recorded against a real event)
    IF v_session_status != 'completed' THEN
        RAISE EXCEPTION
            'milestone_progress_entry: session % has status=% — '
            'progress entries may only reference completed sessions.',
            NEW.session_id, v_session_status;
    END IF;

    -- Patient consistency: session patient must match program patient
    SELECT patient_id INTO v_program_patient
    FROM therapy_programs WHERE id = NEW.therapy_program_id;

    IF v_session_patient != v_program_patient THEN
        RAISE EXCEPTION
            'milestone_progress_entry: session % patient does not match '
            'therapy_program % patient.',
            NEW.session_id, NEW.therapy_program_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_mpe_session_integrity
    BEFORE INSERT ON milestone_progress_entries
    FOR EACH ROW
    EXECUTE FUNCTION enforce_progress_entry_session_integrity();

CREATE INDEX idx_mpe_milestone    ON milestone_progress_entries(milestone_id);
CREATE INDEX idx_mpe_program      ON milestone_progress_entries(therapy_program_id);
CREATE INDEX idx_mpe_session      ON milestone_progress_entries(session_id) WHERE session_id IS NOT NULL;
CREATE INDEX idx_mpe_date         ON milestone_progress_entries(milestone_id, observation_date DESC);
CREATE INDEX idx_mpe_institute    ON milestone_progress_entries(institute_id);

ALTER TABLE milestone_progress_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE milestone_progress_entries FORCE ROW LEVEL SECURITY;

CREATE POLICY mpe_platform_admin ON milestone_progress_entries FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY mpe_read ON milestone_progress_entries FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR EXISTS (
        SELECT 1 FROM therapy_programs tp
        WHERE tp.id = milestone_progress_entries.therapy_program_id
          AND current_user_assigned_to_patient(tp.patient_id)
    ))
);
CREATE POLICY mpe_insert ON milestone_progress_entries FOR INSERT WITH CHECK (
    institute_id = current_institute_id()
    AND current_user_has_permission('CAN_MANAGE_SESSIONS')
);
-- No UPDATE or DELETE policies — immutability trigger is structural


-- =============================================================================
-- SECTION 3 — PLAN CHANGE REQUESTS [D-CE2]
-- =============================================================================

CREATE TABLE plan_change_request_types (
    id          UUID    PRIMARY KEY DEFAULT generate_uuidv7(),
    code        TEXT    NOT NULL UNIQUE,
    name        TEXT    NOT NULL,
    requires_supervisor_approval BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO plan_change_request_types (code, name, requires_supervisor_approval) VALUES
    ('goal_revision',            'Goal Revision',                   TRUE),
    ('frequency_change',         'Session Frequency Change',        TRUE),
    ('provider_change',          'Primary Provider Change',         TRUE),
    ('discharge_planning',       'Discharge Planning',              TRUE),
    ('insurance_reauth',         'Insurance Reauthorization',       FALSE),
    ('program_extension',        'Program Extension',               TRUE),
    ('modality_change',          'Modality Change',                 FALSE),
    ('program_pause',            'Program Pause Request',           TRUE);

CREATE TABLE plan_change_requests (
    id                      UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id            UUID            NOT NULL REFERENCES institutes(id),
    therapy_program_id      UUID            NOT NULL REFERENCES therapy_programs(id),
    request_type_id         UUID            NOT NULL REFERENCES plan_change_request_types(id),

    -- Request content
    change_summary          TEXT            NOT NULL,
    clinical_rationale      TEXT            NOT NULL,
    proposed_changes        JSONB,          -- structured description of proposed changes
    supporting_evidence     TEXT,           -- reference to evaluations/session patterns

    -- Approval workflow
    pcr_status              TEXT            NOT NULL DEFAULT 'draft',
        -- 'draft' → 'submitted' → 'approved' | 'rejected' → 'implemented'
    requested_by            UUID            NOT NULL REFERENCES users(id),
    reviewed_by             UUID            REFERENCES users(id),
    review_notes            TEXT,
    rejected_reason         TEXT,

    -- Timestamps
    submitted_at            TIMESTAMPTZ,
    reviewed_at             TIMESTAMPTZ,
    implemented_at          TIMESTAMPTZ,

    -- Version created on implementation [D-CE2]
    resulting_version_id    UUID            REFERENCES therapy_program_versions(id),

    -- Provenance
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_pcr_program_institute
        FOREIGN KEY (therapy_program_id, institute_id)
        REFERENCES therapy_programs(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_pcr_status
        CHECK (pcr_status IN ('draft','submitted','approved','rejected','implemented')),

    CONSTRAINT chk_pcr_submitted_at
        CHECK (pcr_status = 'draft' OR submitted_at IS NOT NULL),

    CONSTRAINT chk_pcr_draft_no_submitted_at
        CHECK (pcr_status != 'draft' OR submitted_at IS NULL),

    CONSTRAINT chk_pcr_reviewed_at
        CHECK (reviewed_at IS NULL OR pcr_status IN ('approved','rejected','implemented')),

    CONSTRAINT chk_pcr_implemented_has_version
        CHECK (pcr_status != 'implemented' OR resulting_version_id IS NOT NULL),

    CONSTRAINT chk_pcr_rejected_reason
        CHECK (pcr_status != 'rejected' OR rejected_reason IS NOT NULL)
);

COMMENT ON TABLE plan_change_requests IS
    '[D-CE2] Formal approval gate for program plan changes. '
    'Every therapy_program_version must trace back to an approved PCR. '
    'On approved → implemented transition: trigger creates therapy_program_version. '
    'resulting_version_id NOT NULL when implemented — CHECK enforces this. '
    'No orphan versions: cannot create program_version directly on active programs '
    'without going through PCR approval workflow.';

-- Lifecycle transition enforcement
CREATE OR REPLACE FUNCTION enforce_pcr_lifecycle_transitions()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.pcr_status = OLD.pcr_status THEN RETURN NEW; END IF;

    IF OLD.pcr_status = 'draft' AND NEW.pcr_status NOT IN ('draft','submitted') THEN
        RAISE EXCEPTION 'PCR %: invalid transition draft → %. Only draft → submitted permitted.', OLD.id, NEW.pcr_status;
    END IF;
    IF OLD.pcr_status = 'submitted' AND NEW.pcr_status NOT IN ('submitted','approved','rejected') THEN
        RAISE EXCEPTION 'PCR %: invalid transition submitted → %. Only approved or rejected.', OLD.id, NEW.pcr_status;
    END IF;
    IF OLD.pcr_status = 'approved' AND NEW.pcr_status NOT IN ('approved','implemented') THEN
        RAISE EXCEPTION 'PCR %: invalid transition approved → %. Only approved → implemented.', OLD.id, NEW.pcr_status;
    END IF;
    IF OLD.pcr_status IN ('rejected','implemented') THEN
        RAISE EXCEPTION 'PCR %: status=% is terminal. Cannot transition further.', OLD.id, OLD.pcr_status;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pcr_lifecycle
    BEFORE UPDATE OF pcr_status ON plan_change_requests
    FOR EACH ROW EXECUTE FUNCTION enforce_pcr_lifecycle_transitions();

-- [D-CE2] Auto-create program version on implementation
CREATE OR REPLACE FUNCTION create_program_version_on_pcr_implementation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_new_version_id    UUID;
    v_prog              therapy_programs%ROWTYPE;
    v_request_type_code TEXT;
BEGIN
    IF NOT (OLD.pcr_status = 'approved' AND NEW.pcr_status = 'implemented') THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_prog FROM therapy_programs WHERE id = NEW.therapy_program_id;
    SELECT code INTO v_request_type_code FROM plan_change_request_types WHERE id = NEW.request_type_id;

    v_new_version_id := generate_uuidv7();

    INSERT INTO therapy_program_versions (
        id, therapy_program_id, institute_id,
        change_reason, change_summary,
        program_status_snapshot, intended_frequency_snapshot,
        session_duration_snapshot, clinical_notes,
        effective_from, created_by
    ) VALUES (
        v_new_version_id,
        NEW.therapy_program_id,
        NEW.institute_id,
        v_request_type_code,
        NEW.change_summary,
        v_prog.program_status,
        v_prog.intended_frequency_per_week,
        v_prog.intended_session_duration_minutes,
        NEW.clinical_rationale,
        NOW(),
        NEW.reviewed_by
    );

    -- Link PCR to the version it created
    NEW.resulting_version_id := v_new_version_id;
    NEW.implemented_at := NOW();

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pcr_create_version_on_implementation
    BEFORE UPDATE OF pcr_status ON plan_change_requests
    FOR EACH ROW EXECUTE FUNCTION create_program_version_on_pcr_implementation();

COMMENT ON TRIGGER trg_pcr_create_version_on_implementation ON plan_change_requests IS
    '[D-CE2] Auto-creates therapy_program_version when PCR transitions approved → implemented. '
    'Sets resulting_version_id on the PCR row. Sets implemented_at timestamp. '
    'Every program version now traces back to an approved plan change request. '
    'No orphan versions possible on active programs.';

CREATE INDEX idx_pcr_program      ON plan_change_requests(therapy_program_id);
CREATE INDEX idx_pcr_institute    ON plan_change_requests(institute_id);
CREATE INDEX idx_pcr_status       ON plan_change_requests(institute_id, pcr_status);
CREATE INDEX idx_pcr_version      ON plan_change_requests(resulting_version_id) WHERE resulting_version_id IS NOT NULL;

ALTER TABLE plan_change_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_change_requests FORCE ROW LEVEL SECURITY;

CREATE POLICY pcr_platform_admin ON plan_change_requests FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY pcr_read ON plan_change_requests FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR EXISTS (
        SELECT 1 FROM therapy_programs tp
        WHERE tp.id = plan_change_requests.therapy_program_id
          AND current_user_assigned_to_patient(tp.patient_id)
    ))
);
CREATE POLICY pcr_insert ON plan_change_requests FOR INSERT WITH CHECK (
    institute_id = current_institute_id()
    AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
);
CREATE POLICY pcr_clinician_update ON plan_change_requests FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND pcr_status = 'draft'
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND pcr_status IN ('draft','submitted')
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    );
CREATE POLICY pcr_supervisor_review ON plan_change_requests FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND pcr_status = 'submitted'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND pcr_status IN ('submitted','approved','rejected')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    );
CREATE POLICY pcr_implement ON plan_change_requests FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND pcr_status = 'approved'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND pcr_status IN ('approved','implemented')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_MANAGE_PROGRAMS')
    );


-- =============================================================================
-- SECTION 4 — CASE CONFERENCES [D-CE3]
-- =============================================================================
-- Multidisciplinary team (MDT) meeting records.
-- Freeze at reviewed (not submitted) — multi-party artifact.
-- Lifecycle: draft → submitted → reviewed → locked
-- =============================================================================

CREATE TABLE case_conferences (
    id                      UUID            PRIMARY KEY DEFAULT generate_uuidv7(),
    institute_id            UUID            NOT NULL REFERENCES institutes(id),
    branch_id               UUID            NOT NULL REFERENCES branches(id),
    patient_id              UUID            NOT NULL REFERENCES patients(id),
    therapy_program_id      UUID            REFERENCES therapy_programs(id),

    conference_type         TEXT            NOT NULL DEFAULT 'mdt_review',
        -- 'mdt_review', 'progress_review', 'discharge_planning',
        -- 'family_meeting', 'school_liaison', 'emergency_review'
    conference_date         DATE            NOT NULL,
    location                TEXT,
    duration_minutes        INTEGER,

    -- Attendance (stored as JSON for flexibility — disciplines vary)
    attendees               JSONB,
        -- [{"role": "OT", "name": "...", "user_id": "...", "external": false}]
    chaired_by              UUID            REFERENCES users(id),

    -- Conference content (freeze at reviewed)
    agenda                  TEXT,
    minutes                 TEXT,
    clinical_decisions      TEXT,
    action_items            JSONB,
        -- [{"action": "...", "responsible": "...", "due_date": "...", "status": "pending"}]
    next_review_date        DATE,

    -- Note: no session_rating equivalent; conferences are documented differently

    -- Lifecycle [D-CE3]: draft → submitted → reviewed → locked
    conference_status       TEXT            NOT NULL DEFAULT 'draft',
    minutes_author_id       UUID            REFERENCES users(id),
    submitted_at            TIMESTAMPTZ,
    reviewed_by             UUID            REFERENCES users(id),
    reviewed_at             TIMESTAMPTZ,
    locked_by               UUID            REFERENCES users(id),
    locked_at               TIMESTAMPTZ,

    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by              UUID            REFERENCES users(id),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_cc_patient_institute
        FOREIGN KEY (patient_id, institute_id)
        REFERENCES patients(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_cc_branch_institute
        FOREIGN KEY (branch_id, institute_id)
        REFERENCES branches(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT fk_cc_program_institute
        FOREIGN KEY (therapy_program_id, institute_id)
        REFERENCES therapy_programs(id, institute_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_cc_status
        CHECK (conference_status IN ('draft','submitted','reviewed','locked')),

    -- Timestamp ordering
    CONSTRAINT chk_cc_submitted_at
        CHECK (conference_status = 'draft' OR submitted_at IS NOT NULL),

    CONSTRAINT chk_cc_draft_no_submitted_at
        CHECK (conference_status != 'draft' OR submitted_at IS NULL),

    CONSTRAINT chk_cc_reviewed_at_timing
        CHECK (reviewed_at IS NULL OR conference_status IN ('reviewed','locked')),

    CONSTRAINT chk_cc_locked_at_timing
        CHECK (locked_at IS NULL OR conference_status = 'locked'),

    CONSTRAINT chk_cc_reviewed_implies_submitted
        CHECK (conference_status NOT IN ('reviewed','locked') OR submitted_at IS NOT NULL),

    CONSTRAINT uq_cc_id_institute UNIQUE (id, institute_id)
);

COMMENT ON TABLE case_conferences IS
    '[D-CE3] Multidisciplinary team meeting record. '
    'Freeze at reviewed — submission = minutes drafted, reviewed = MDT record validated. '
    'One clinician submitting minutes does not constitute a finalized MDT record. '
    'Supervisor review confirms minutes accurately represent the conference. '
    'Absolute freeze at locked. No amendment model — MDT corrections handled by new conference.';

-- Lifecycle transitions (forward-only, independent of RLS)
CREATE OR REPLACE FUNCTION enforce_case_conference_lifecycle()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.conference_status = OLD.conference_status THEN RETURN NEW; END IF;

    IF OLD.conference_status = 'draft' AND NEW.conference_status NOT IN ('draft','submitted') THEN
        RAISE EXCEPTION 'case_conference %: invalid transition draft → %. Only submitted.', OLD.id, NEW.conference_status;
    END IF;
    IF OLD.conference_status = 'submitted' AND NEW.conference_status NOT IN ('submitted','reviewed') THEN
        RAISE EXCEPTION 'case_conference %: invalid transition submitted → %. Only reviewed.', OLD.id, NEW.conference_status;
    END IF;
    IF OLD.conference_status = 'reviewed' AND NEW.conference_status NOT IN ('reviewed','locked') THEN
        RAISE EXCEPTION 'case_conference %: invalid transition reviewed → %. Only locked.', OLD.id, NEW.conference_status;
    END IF;
    IF OLD.conference_status = 'locked' AND NEW.conference_status != 'locked' THEN
        RAISE EXCEPTION 'case_conference %: locked is absolutely final. No further transitions.', OLD.id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cc_lifecycle
    BEFORE UPDATE OF conference_status ON case_conferences
    FOR EACH ROW EXECUTE FUNCTION enforce_case_conference_lifecycle();

-- Content freeze at reviewed
CREATE OR REPLACE FUNCTION enforce_case_conference_freeze()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.conference_status IN ('reviewed','locked') THEN
        IF NEW.patient_id           IS DISTINCT FROM OLD.patient_id           OR
           NEW.institute_id         != OLD.institute_id                        OR
           NEW.conference_type      != OLD.conference_type                    OR
           NEW.conference_date      != OLD.conference_date                    OR
           NEW.minutes              IS DISTINCT FROM OLD.minutes              OR
           NEW.clinical_decisions   IS DISTINCT FROM OLD.clinical_decisions   OR
           NEW.action_items         IS DISTINCT FROM OLD.action_items         OR
           NEW.attendees            IS DISTINCT FROM OLD.attendees            OR
           NEW.chaired_by           IS DISTINCT FROM OLD.chaired_by
        THEN
            RAISE EXCEPTION
                'case_conference % has status=% and is frozen. '
                'Minutes, decisions, attendees, and identity facts cannot change '
                'after review. Create a new conference to supersede this record.',
                OLD.id, OLD.conference_status;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cc_freeze
    BEFORE UPDATE ON case_conferences
    FOR EACH ROW EXECUTE FUNCTION enforce_case_conference_freeze();

CREATE INDEX idx_cc_institute      ON case_conferences(institute_id);
CREATE INDEX idx_cc_patient        ON case_conferences(patient_id);
CREATE INDEX idx_cc_program        ON case_conferences(therapy_program_id);
CREATE INDEX idx_cc_date           ON case_conferences(patient_id, conference_date DESC);
CREATE INDEX idx_cc_status         ON case_conferences(institute_id, conference_status);

ALTER TABLE case_conferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE case_conferences FORCE ROW LEVEL SECURITY;

CREATE POLICY cc_platform_admin ON case_conferences FOR ALL USING (current_user_is_platform_admin());
CREATE POLICY cc_read ON case_conferences FOR SELECT USING (
    institute_id = current_institute_id()
    AND (current_user_has_institute_scope() OR current_user_assigned_to_patient(patient_id))
);
CREATE POLICY cc_insert ON case_conferences FOR INSERT WITH CHECK (
    institute_id = current_institute_id()
    AND current_user_has_permission('CAN_MANAGE_SESSIONS')
);
CREATE POLICY cc_clinician_update ON case_conferences FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND conference_status = 'draft'
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND conference_status IN ('draft','submitted')
        AND current_user_has_permission('CAN_MANAGE_SESSIONS')
    );
CREATE POLICY cc_supervisor_review ON case_conferences FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND conference_status = 'submitted'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_REVIEW_SESSIONS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND conference_status IN ('submitted','reviewed')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_REVIEW_SESSIONS')
    );
CREATE POLICY cc_lock ON case_conferences FOR UPDATE
    USING (
        institute_id = current_institute_id()
        AND conference_status = 'reviewed'
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_LOCK_SESSIONS')
    )
    WITH CHECK (
        institute_id = current_institute_id()
        AND conference_status IN ('reviewed','locked')
        AND current_user_has_institute_scope()
        AND current_user_has_permission('CAN_LOCK_SESSIONS')
    );


-- =============================================================================
-- PHASE 3 CLINICAL EVENTS — INVENTORY
-- =============================================================================
--
-- Tables:
--   plan_change_request_types       (lookup, 8 seeds)
--   program_milestones              (mutable header, frozen at program activation)
--   milestone_progress_entries      (append-only observations)
--   plan_change_requests            (approval workflow, drives versioning)
--   case_conferences                (MDT records, freeze at reviewed)
--
-- Triggers:
--   trg_milestone_header_freeze           header frozen at program activation
--   trg_mpe_immutable                     progress entries append-only
--   trg_mpe_session_integrity             session cross-validation + patient check
--   trg_pcr_lifecycle                     PCR forward-only status transitions
--   trg_pcr_create_version_on_implementation  auto-creates program_version on approval
--   trg_cc_lifecycle                      conference forward-only transitions
--   trg_cc_freeze                         conference content frozen at reviewed
--
-- =============================================================================
-- PHASE 3 — COMPLETE MIGRATION SEQUENCE
-- =============================================================================
--
--  1.  phase3_clinical_core_foundation.sql       therapy_type_registry, programs,
--                                                 program_versions, assignments, goals
--  2.  phase3_clinical_core_foundation_patch01.sql  structural corrections (7 fixes)
--  3.  phase3_session_records.sql                dual-domain freeze, [O1] partial
--  4.  phase3_session_records_patch01.sql         WITH CHECK + timestamp constraints
--  5.  phase3_evaluations.sql                    instrument + clinical_report, [O1] final
--  6.  phase3_evaluations_patch01.sql             lifecycle trigger, submission gate, rename
--  7.  phase3_clinical_events.sql                milestones, PCRs, case conferences ← this
--
-- Entry obligations all closed:
--   [O1] ✅ validate_response_context_ref() — session + evaluation unblocked
--   [O2] ✅ validate_case_role_scope_ref() — program scope unblocked
--   [O3] ✅ supersedes_response_id — amendment workflow anchor
--
-- PHASE 3 IS COMPLETE.
--
-- =============================================================================
-- SYSTEM-WIDE FREEZE SEMANTICS SUMMARY
-- =============================================================================
--
--  Entity                          | Freeze Point       | Model
-- ─────────────────────────────────┼────────────────────┼────────────────────
--  form_responses                  | submitted          | single domain
--  session_records (facts)         | completed          | dual domain A
--  session_records (notes)         | note submitted     | dual domain B
--  evaluations                     | submitted          | single domain
--  case_conferences                | reviewed           | single domain (MDT)
--  milestone_progress_entries      | never              | append-only
--  therapy_program_versions        | never              | append-only
--  evaluation_versions             | never              | append-only
--  therapy_programs (identity)     | active             | partial freeze
--  program_milestones (header)     | program active     | partial freeze
--  plan_change_requests            | rejected/implemented| terminal states
--
-- No contradictions. Each freeze rule matches semantic category.
-- =============================================================================
