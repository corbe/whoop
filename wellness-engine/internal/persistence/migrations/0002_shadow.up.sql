-- Shadow comparison storage (STAGE 19B, PART B).
-- Isolated from official wellness tables: the Go shadow writes ONLY here.
-- No raw physiological streams — inputs are referenced by fingerprint.
CREATE TABLE IF NOT EXISTS wellness_shadow_comparison (
    id                  BIGSERIAL PRIMARY KEY,
    person_hash         TEXT        NOT NULL,           -- HMAC pseudonym, never a raw identifier
    logical_day         DATE        NOT NULL,
    input_fingerprint   TEXT        NOT NULL,           -- canonical input fingerprint (idempotency)
    official_sleep      SMALLINT,
    official_stress     SMALLINT,
    official_readiness  SMALLINT,
    official_activity   SMALLINT,
    shadow_sleep        SMALLINT,
    shadow_stress       SMALLINT,
    shadow_readiness    SMALLINT,
    shadow_activity     SMALLINT,
    delta_sleep         SMALLINT,
    delta_stress        SMALLINT,
    delta_readiness     SMALLINT,
    delta_activity      SMALLINT,
    match_class         TEXT        NOT NULL,           -- EXACT | EXPECTED_ONLY | MISMATCHED | INPUT_INCOMPLETE
    formula_version     TEXT        NOT NULL,
    config_hash         TEXT        NOT NULL,
    engine_version      TEXT        NOT NULL,
    go_run_id           BIGINT,                        -- references wellness_calculation_run when persisted
    official_reference  TEXT,                          -- official run/reference id (Dart side)
    failure_code        TEXT,                          -- adapter/engine failure, when the case failed
    compared_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (person_hash, logical_day, input_fingerprint)
);
CREATE INDEX IF NOT EXISTS wellness_shadow_comparison_person_idx
    ON wellness_shadow_comparison (person_hash, logical_day);
CREATE INDEX IF NOT EXISTS wellness_shadow_comparison_class_idx
    ON wellness_shadow_comparison (match_class);
