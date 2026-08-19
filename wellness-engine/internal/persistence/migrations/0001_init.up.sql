-- 0001_init.up.sql — wellness score persistence (STAGE 15)
-- Design source: docs/wellness-persistence-design.md (STAGE 14).
-- Postgres 15+ (partial unique indexes, jsonb).

CREATE TABLE wellness_formula_version (
    formula_key   text        NOT NULL,
    version       int         NOT NULL,
    status        text        NOT NULL DEFAULT 'ACTIVE',  -- DRAFT|ACTIVE|RETIRED
    name          text,
    description   text,
    config_hash   text,
    parameters    jsonb       NOT NULL DEFAULT '{}',
    valid_from    timestamptz,
    valid_to      timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (formula_key, version)
);

-- exactly one ACTIVE version per formula key
CREATE UNIQUE INDEX uq_formula_version_active
    ON wellness_formula_version (formula_key) WHERE status = 'ACTIVE';

CREATE TABLE wellness_calculation_run (
    run_id            bigserial   PRIMARY KEY,
    person_id         text        NOT NULL,
    logical_day       date        NOT NULL,
    timezone          text        NOT NULL,
    input_fingerprint text        NOT NULL,
    config_hash       text        NOT NULL,
    engine_version    text        NOT NULL,
    formula_versions  jsonb       NOT NULL,
    quality           jsonb,
    calculated_at     timestamptz NOT NULL,
    replaces_run_id   bigint      REFERENCES wellness_calculation_run (run_id),
    -- idempotency: same semantic calculation → same run (calculated_at is
    -- deliberately NOT part of this key)
    UNIQUE (person_id, logical_day, input_fingerprint, config_hash, engine_version)
);

CREATE INDEX ix_run_person_day ON wellness_calculation_run (person_id, logical_day DESC);

CREATE TABLE wellness_daily_score (
    score_id        bigserial   PRIMARY KEY,
    run_id          bigint      NOT NULL REFERENCES wellness_calculation_run (run_id) ON DELETE CASCADE,
    person_id       text        NOT NULL,
    logical_day     date        NOT NULL,
    formula_key     text        NOT NULL,
    formula_version int         NOT NULL,
    config_hash     text        NOT NULL,
    score           smallint    NOT NULL,
    explanation     jsonb       NOT NULL,  -- components/steps/warnings/missing
    is_current      boolean     NOT NULL DEFAULT false,
    -- per-run uniqueness (idempotent replay of the same run)
    UNIQUE (run_id, formula_key)
);

-- exactly one CURRENT score per (person, day, formula)
-- (partial predicates require a standalone index, not a table constraint)
CREATE UNIQUE INDEX uq_score_current
    ON wellness_daily_score (person_id, logical_day, formula_key) WHERE is_current;

CREATE INDEX ix_score_history
    ON wellness_daily_score (person_id, formula_key, logical_day DESC, run_id DESC);

CREATE TABLE wellness_goal_state (
    goal_id         bigserial   PRIMARY KEY,
    person_id       text        NOT NULL,
    goal_key        text        NOT NULL,  -- goal_steps | goal_sleep
    value           int         NOT NULL,  -- steps or sleep-target minutes
    bed_time_minutes int,                  -- sleep goal only
    reason          text        NOT NULL,  -- applied|manual_override_active|cooldown_active|... (goals.Reason)
    source          text        NOT NULL,  -- auto|manual|seed
    formula_key     text,
    config_hash     text,
    run_id          bigint      REFERENCES wellness_calculation_run (run_id),
    applied_at      timestamptz NOT NULL,
    superseded_at   timestamptz,
    -- one row per (person, goal_key, run) — history is append-only
    UNIQUE (person_id, goal_key, run_id)
);

-- exactly one current goal per (person, goal_key)
CREATE UNIQUE INDEX uq_goal_current
    ON wellness_goal_state (person_id, goal_key) WHERE superseded_at IS NULL;

CREATE INDEX ix_goal_history ON wellness_goal_state (person_id, goal_key, applied_at DESC);

CREATE TABLE wellness_baseline_snapshot (
    snapshot_id bigserial   PRIMARY KEY,
    person_id   text        NOT NULL,
    logical_day date        NOT NULL,
    metrics     jsonb       NOT NULL,
    run_id      bigint      NOT NULL REFERENCES wellness_calculation_run (run_id) ON DELETE CASCADE,
    UNIQUE (person_id, logical_day, run_id)
);

CREATE INDEX ix_baseline_person_day ON wellness_baseline_snapshot (person_id, logical_day DESC);
