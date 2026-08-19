# Wellness Score Persistence — Design (STAGE 14) + Implementation (STAGE 15)

**Status:** STAGE 14 design COMPLETE → **STAGE 15 implemented** on
`feat/go-wellness-engine` (schema + repositories + atomic bundle write +
integration tests against real Postgres).
**No API/Flutter/deploy yet (STAGE 16+).**

## 0. Principles

1. Persist RESULTS + METADATA, not raw physiological streams. Raw data stays
   in its canonical storage (Isar today / future raw-data store); the score
   layer references it by fingerprint.
2. Reproducibility: every historical score must answer "what ran, with which
   version, config and input".
3. No destructive overwrite — revisions, never silent replacement.
4. Idempotency enforced by the DATABASE (unique keys), not app locks.

## 1. What must be persisted (from CalculationBundle)

| Bundle field | Persisted as |
|---|---|
| Scores (sleep/stress/readiness/activity) | wellness_daily_score |
| Explanations (components/steps) | JSONB on the score row (never queried independently) |
| Warnings/Missing | JSONB on the score row |
| Goal updates + goal state | wellness_goal_state (current + history) |
| Baseline snapshot (RHR/SpO2/steps/confidence used) | wellness_baseline_snapshot |
| Formula versions (all six keys) | wellness_calculation_run (per-key versions in JSONB) |
| config_hash | column (wellness_calculation_run + score rows) |
| engine_version | column (wellness_calculation_run) |
| input fingerprint | column (wellness_calculation_run) |
| calculated_at / run time | column (metadata only; never identity) |
| Recalculation lineage | wellness_calculation_run.replaces_run_id |

## 2. Data model (5 tables)

### wellness_formula_version
- PURPOSE: DB-backed formula registry (replaces versioning.DefaultRegistry
  at runtime; the calculation core still consumes typed config, never SQL).
- PK: `(formula_key, version)`. Columns: formula_key, version, status
  (DRAFT|ACTIVE|RETIRED), name, description, valid_from, valid_to,
  parameters JSONB (typed config decoded with strict validation — unknown
  keys rejected), created_at.
- Constraint: at most one ACTIVE per formula_key (partial unique index).
- Retention: permanent (config history is the audit trail).

### wellness_calculation_run
- PURPOSE: one calculation bundle execution — the unit of idempotency and
  lineage.
- PK: run_id (bigserial/uuid). Columns: person_id, logical_day (date,
  device-local semantics — timezone recorded separately), timezone,
  input_fingerprint (text), config_hash, engine_version,
  formula_versions JSONB (`{"sleep":1,...}`), quality JSONB (warnings +
  missing), calculated_at, replaces_run_id (FK self, nullable).
- UNIQUE: `(person_id, logical_day, input_fingerprint, config_hash,
  engine_version, formula_versions)` → same semantic calculation twice =
  same run.
- Indexes: (person_id, logical_day DESC), (person_id, replaces_run_id).

### wellness_daily_score
- PURPOSE: current + historical score per formula per person/day.
- PK: score_id. Columns: run_id FK, person_id, logical_day, formula_key,
  formula_version, config_hash, score (smallint), explanation JSONB
  (components/steps/reasons), is_current boolean.
- UNIQUE idempotency key: `(person_id, logical_day, formula_key,
  formula_version, config_hash, run_id)` — one row per run; the
  `is_current` partial unique index
  `UNIQUE (person_id, logical_day, formula_key) WHERE is_current` enforces
  exactly one current score.
- Indexes: (person_id, logical_day DESC, formula_key),
  (person_id, formula_key, logical_day DESC) WHERE is_current.
- Retention: keep all revisions (audit); pruning is a product decision.

### wellness_goal_state
- PURPOSE: current goal + history for goal_steps / goal_sleep (bedtime,
  sleep target).
- Columns: goal_id PK, person_id, goal_key (goal_steps|goal_sleep),
  value (steps or target minutes), bed_time_minutes (nullable, sleep),
  reason (applied|manual|seeded|...) , source (auto|manual|seed),
  applied_at, run_id FK (nullable — manual edits have no run),
  superseded_at (nullable).
- Unique current: partial unique on (person_id, goal_key) WHERE
  superseded_at IS NULL.
- Index: (person_id, goal_key, applied_at DESC).

### wellness_baseline_snapshot
- PURPOSE: the RHR/SpO2/steps/confidence values the scores consumed for a
  day (inputs to F-03 optional components and F-08/F-09).
- Columns: snapshot_id PK, person_id, logical_day, rhr_baseline,
  spo2_baseline, steps_baseline (value + sample_count + confidence per
  metric, JSONB metrics), run_id FK.
- UNIQUE: (person_id, logical_day, run_id).
- Retention: keep with run (bundle audit).

## 3. Idempotency key

```
(person_id, logical_day, formula_key, formula_version, config_hash, input_fingerprint)
```

- calculated_at is NEVER identity.
- Same semantics → same run row (ON CONFLICT DO NOTHING → return existing).
- Changed input (fingerprint), changed config (hash) or changed version →
  NEW run → new revision, previous stays as history.

## 4. Input fingerprint

Canonical deterministic serialization of the pure `engine.Input`
physiological fields (same encoder as the config hash: declaration order,
'g' floats, quoted strings; slices ordered, steps records sorted by
timestamp, segments by start_ms). Excluded: person_id, date, location,
Now (metadata). Same semantics → same fingerprint; row ordering / JSON
formatting cannot change it. PII: none — fingerprints contain only
sanitized physiological values, no identity.

## 5. Revision model

- Run R with fingerprint F1 → scores revision 1 (is_current).
- Raw data corrected → F2 → run R2 (replaces_run_id = R) → revision 2
  (is_current flips); revision 1 remains queryable.
- Formula/config change → new config_hash/version → same flow.
- No DELETE; "current" is a derived flag set inside the transaction.

## 6. Transaction boundary

ONE transaction per bundle (all-or-nothing):
```
BEGIN
  insert wellness_calculation_run (run_id)
  upsert wellness_daily_score rows (scores + explanations, is_current flip)
  insert wellness_goal_state history rows (+ flip current if updated)
  insert wellness_baseline_snapshot
COMMIT
```
A partially persisted calculation can never become current (single
transaction; score rows reference run_id which exists only after commit).

## 7. Concurrency

- Idempotency via DB unique keys (3 + 2): concurrent identical bundles →
  one row (conflict → DO NOTHING, return existing).
- Concurrent DIFFERENT bundles for same person/day → different fingerprint
  → both runs persist; is_current flip is last-writer-wins on the partial
  unique index (deterministic by run ordering). Expected conflict behavior:
  the second run supersedes; both remain auditable.
- No application locks; no advisory locks needed for correctness.

## 8. JSONB vs columns

- COLUMNS: person_id, logical_day, formula_key, version, config_hash,
  score, run_id (identity + frequent filters + FK).
- JSONB: explanation components/steps, quality (warnings/missing),
  formula_versions map, baseline metrics, goal parameters.
- Rationale: components are fetched ONLY with their score (no standalone
  queries); JSONB keeps the bundle atomic inside the transaction and avoids
  5–10 child tables. Raw data is NOT duplicated (fingerprint reference).
- Explicitly NOT normalized: score components (see above), goal parameters
  (one row per formula version, not per parameter).

## 9. Repository boundary (interfaces only — no pgx yet)

```go
// internal/repository (interfaces; STAGE 15 implements with pgx)
type RunRepository interface {
    InsertRun(ctx, run CalculationRun) (RunID, bool created, error) // idempotent
    GetRun(ctx, id RunID) (CalculationRun, error)
}
type ScoreRepository interface {
    UpsertScores(ctx, runID RunID, scores []DailyScore) error
    CurrentScore(ctx, personID, day, formulaKey) (DailyScore, error)
    ScoreHistory(ctx, personID, day, formulaKey) ([]DailyScore, error)
}
type GoalRepository interface {
    CurrentGoal(ctx, personID, goalKey) (GoalState, error)
    AppendGoalChange(ctx, g GoalState) error
}
type BaselineRepository interface {
    Snapshot(ctx, s BaselineSnapshot) error
    CurrentBaseline(ctx, personID) (BaselineSnapshot, error)
}
type RegistryStore interface { // replaces versioning.DefaultRegistry
    ActiveVersions(ctx) (map[versioning.Key]versioning.FormulaVersion, error)
}
```

## 10. Query requirements (supported)

latest score, score history, score detail/explanation (JSONB), current
goal, goal history, current baseline, calculation revisions
(replaces_run_id chain), formula/config used for a historical score
(columns on score + run). No hypothetical extra indexes.

## 11. Privacy

- Only bundle outputs + fingerprints persisted; no raw HR/HRV/SpO2/steps
  streams in the score layer.
- Fingerprints carry no identity (sanitized values only).
- No PII in fixtures/docs (existing golden datasets are synthetic).

## 12. Retention (policy — durations are PRODUCT/LEGAL decisions)

| Category | Proposal |
|---|---|
| formula_version | permanent (audit) |
| calculation_run | keep; archive after PRODUCT decision |
| daily_score revisions | keep all (audit); product may cap revisions per day |
| baseline_snapshot | keep with run |
| goal_state | keep all changes (audit) |

No deletion implemented; legal retention periods to be defined with the
product/legal team (BR LGPD applies — duration UNKNOWN until then).

## 13. Migration strategy (STAGE 15+)

1. Add tables (no data migration — no production scores exist yet).
2. Seed wellness_formula_version from versioning.DefaultRegistry (v1 rows).
3. Backfill: calculate+persist historical days for active users (bounded
   job, per user/day, idempotent via the unique keys).
4. Switch the calculation entry point to run inside the repository
   transaction; engine stays pure.

## 14. STAGE 15 implementation notes

### Schema (migration 0001_init.up.sql — embedded, applied by `postgres.Migrate`)

As designed, with one correction: Postgres does not allow partial predicates
in table-level constraints, so the current-score and current-goal partial
uniques are standalone `CREATE UNIQUE INDEX ... WHERE` statements. The goal
table also gained `UNIQUE (person_id, goal_key, run_id)` so history is
append-only per run (no duplicate rows when a run applies two changes).

### Repository implementations (`internal/persistence/postgres`)

- `Store` implements `repository.Store`: `PersistBundle`, `CurrentScore`,
  `ScoreHistory`, `RunRevisions`, `CurrentGoal`, `GoalHistory`,
  `CurrentBaseline`; `ActiveVersion` implements `repository.RegistryStore`;
  `SeedFormulaVersions` registers the parity v1 rows (idempotent, ON
  CONFLICT DO NOTHING, parameters = serialized `engine.DefaultConfigs()`).
- Projection: `persistence.ProjectBundle(engine.Input, *engine.CalculationBundle)`
  builds the repository shape — explanations are stored as typed JSONB
  payloads (stable JSON tags added to `explain.Explanation`), quality as
  JSONB, goal changes only when the run applied one, baseline snapshot as
  JSONB metrics (no raw physiological streams duplicated).
- Input fingerprint: `engine.Input.Fingerprint()` (internal/engine) using
  the shared canonical encoder (`versioning.CanonicalString`, time.Time by
  UnixNano); order-independent via sorting of segments/battery/steps;
  PersonID/Date/Location/Now excluded.

### Transaction semantics

One `BEGIN/COMMIT` per bundle: advisory xact lock per (person, day) →
previous-current lookup → idempotent run insert (RETURNING run_id; conflict
= replay) → flip old current → insert new score rows → goal history
(supersede + append) → baseline snapshot. Any failure → ROLLBACK; a partial
calculation can never become current (test: corrupt JSONB → 0 rows).

### Idempotency

DB-enforced: run UNIQUE (person_id, logical_day, input_fingerprint,
config_hash, engine_version) + score UNIQUE (run_id, formula_key). Replay
returns `repository.ErrDuplicateRun` (a sentinel, not an error condition)
without touching current rows. Not an app-level check.

### Concurrency

`pg_advisory_xact_lock(hashtextextended(person|day))` serializes writers for
the same person/day at the DB; the loser flips after the winner commits
(last writer wins). Tested: 8 concurrent identical bundles → 1 run/4 current
rows; concurrent different bundles → both runs, exactly 1 current per
formula; `-count=5` on the concurrency tests is stable.

### Revisions

New input/config/version → new run with replaces_run_id = previous current
run; is_current flips inside the tx; history rows immutable. Tested:
v1 → v2 chain, order, current flags.

### Migration tests

Empty DB → migrate up → 5 tables + re-migrate idempotent. No down
migrations (nothing destructive added for symmetry).

### Test database

Real Postgres required (constraints/transactions/JSONB cannot be mocked):
`TEST_DATABASE_URL` env wins; otherwise a `postgres:16-alpine` container is
started via Docker (skipped when Docker is unavailable). Each test truncates
its tables (hermetic, -count=N safe).

### B.2 through persistence

Persist → read back: sleep 90 / stress 40 / readiness 78 / activity 78
EXACTLY; formula versions, config_hash, engine_version, explanation JSONB
(5 readiness components), quality payload, fingerprint and revision lineage
all verified (`TestPersistB2AndReadBack`).
