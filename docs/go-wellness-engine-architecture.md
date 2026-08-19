# Go Wellness Engine — Architecture Design

**Based on:** docs/wellness-formula-audit.md (F-01..F-16),
docs/wellness-formula-dependencies.md, docs/wellness-input-contract.md,
docs/wellness-golden-dataset.md, docs/wellness-formula-classification.md
**Repository:** noana-org/ritma-app, branch `feat/go-wellness-engine`

## 1. Mission restated from evidence

ritma-app computes 4 daily scores (sleep, stress, readiness, activity) plus
adaptive goals (steps/bedtime/sleep-duration) from bracelet data. The Go engine
must reproduce them EXACTLY (same input + same formula version → same result),
with versioned/configurable parameters, explanations, idempotent persistence —
but it must NOT translate the app's device/BLE/UI layers.

Evidence-driven constraints:
- ALL day/night windows are LOCAL-TIMEZONE (no UTC, no tz parameter). The Go
  engine needs an explicit `timezone` input per person (the app implicitly uses
  device local time; the backend must resolve the user's tz — REQUIRED NEW
  capability, see Risks).
- Scores are int 0–100; 0 means "no data" (never a bad score).
- Steps are CUMULATIVE daily counters (peak aggregation) — the input contract
  must keep this semantic.
- HRV is device-computed (ms, assumed RMSSD) — the engine consumes it as-is.
- RHR = P10 within the sleep window; baselines use MEDIAN (RHR/steps/bedtime/
  duration) or MEAN (SpO2/HRV) + shrinkage to priors.
- F-12 (night pipeline: gap-fill + 1h-awake expunge + 16h cap) is the
  highest-risk logic — port it first with golden cases N1–N5.

## 2. Module layout

```
wellness-engine/
  cmd/wellness-engine/          # CLI + HTTP service (Phase 11)
  internal/
    domain/                     # pure types: Measurement, Metric, Score, ...
    metrics/                    # raw metric normalization (HR/HRV/SpO2/steps)
    night/                      # F-12 night pipeline (gap-fill, expunge, cap)
    baseline/                   # F-05/F-06/F-13/F-14 rolling baselines
    scoring/
      sleep/                    # F-01
      stress/                   # F-02
      readiness/                # F-03
      activity/                 # F-04
    lifestyle/                  # F-08/F-09 adaptive goals (auto-update)
    explanation/                # breakdown + codes (msg1/2/3)
    versioning/                 # formula versions + params
    engine/                     # orchestration (calculate day)
    store/                      # persistence adapters (interfaces)
    observability/              # metrics/logging
  pkg/wellness/                 # public API types (Draft: keep minimal)
  testdata/golden/              # oracle.json + Go golden tests
  docs/
```

Deviations from the suggested skeleton (justified):
- `normalization/` merged into `metrics/` (the app has only 4 normalization
  primitives: validity filters, daily means, ln-domain, peak-counter — a
  separate package would be ceremony).
- Added `night/` — F-12 is a distinct, high-risk, testable stage.
- `formulas/` split per score (each score file is small; per-score packages
  keep golden tests colocated).

## 3. Core domain types (no map[string]interface{})

```go
type Measurement struct {           // one raw sample
    PersonID   string
    Metric     Metric               // heart_rate, hrv_ms, spo2_pct, steps, ...
    Timestamp  time.Time            // epoch ms precision
    Value      float64
    Device     DeviceSource         // bracelet | api
    // steps only:
    Calories   *float64
    DistanceM  *float64
}

type DailyMetrics struct {          // per person/day, computed once
    Day         time.Time           // local midnight
    Night       *NightSummary       // F-12
    Steps       int                 // peak
    KcalWearable float64
    SessionKcal int
    HRVDaily    []float64           // daily averages, ascending day
    ...
}

type Baseline struct {
    Value       float64
    Prior       float64
    SampleCount int
    Confidence  BaselineConfidence  // none|early|provisional|good|optimal
}

type ScoreComponent struct {
    Key             string          // "sleep","recovery","rhr","spo2","fatigue"
    RawValue        float64         // component raw input (e.g. ratio, delta)
    NormalizedValue float64         // 0..100 component score
    Weight          float64         // configured weight (0 if absent)
    Present         bool
}

type Score struct {
    Key        string             // "sleep","stress","readiness","activity"
    Value      int                // 0..100; 0 = no data
    FormulaKey string
    Version    int
    ConfigHash string
    Components []ScoreComponent
    Codes      map[string]int     // sleep msg1/msg2/msg3, downCount, etc.
    CalculatedAt time.Time
}
```

## 4. Pure calculation core (Phases 7, 10)

All scoring packages are pure: `func(ctx, Inputs, Config) (Score, error)` —
no I/O inside. `engine.Calculate` is the only impure seam (it loads inputs
through `store` interfaces and calls the pure functions).

Determinism contract:
- Same Inputs + same Config version + same timezone → byte-identical result.
- All arithmetic follows Dart semantics: IEEE754 doubles in the same
  operation ORDER (esp. F-01 discounts, F-02 ln/sigmoid, pctLight artifact);
  `.round()` = half away from zero; `.toInt()` = truncation; `.ceil()` where
  specified; `clamp` order preserved.
- Dates: all day keys derived from `time.Date(y,m,d,0,0,0,0,loc)`.

## 5. Formula versioning (Phase 8)

```sql
formula(id, key UNIQUE, name, description, created_at)
formula_version(id, formula_id FK, version, status DRAFT|ACTIVE|RETIRED,
                valid_from, valid_to NULL, parameters JSONB, config_hash,
                created_at)
calculation(person_id, day, formula_key, version, config_hash, value,
            input_digest, calculated_at, UNIQUE(person_id, day, formula_key,
            version, input_digest))   -- idempotency key, see §8
calculation_component(calculation_id FK, key, raw_value, normalized_value,
                      weight, present)
baseline_snapshot(person_id, baseline_key, day, value, prior, sample_count,
                  confidence, created_at)
```

- The DB stores ONLY safe parameters (weights, thresholds, windows, clamps).
  Algorithm structure lives in versioned Go code (constants frozen per
  version in code, NOT read from DB) — matches ritma-app reality, where all
  algorithm structure is code and only calibration numbers are data.
- `config_hash` = sha256 of the effective parameter set → historical
  reproducibility without storing config blobs per row.

## 6. Configurable vs code (Phase 9 — see formula-configuration-decisions.md)

Summary: weights/thresholds/windows/min-samples → configurable (they are
already calibration objects in Dart). Mathematical invariants (ln domain,
sigmoid shape, peak-counter semantics, P10/median/mean choice, gap-fill rules,
16h cap, stage encoding) → stay in code. Dead Dart parameters are NOT ported
as config; they are documented and omitted (or kept only as no-op fields for
diff-parity, see decisions doc §3).

## 7. Baseline engine (Phase 11)

Port ONLY the proven algorithms:
- RHR nightly: P10 nearest-rank of HR in night window (filter 30<x<220).
- RHR rolling: median of last 30 nightly P10s, shrinkage w=n/30 vs prior 65.
- SpO2 nightly: mean of samples 70–100 in window (raw collection; filtered
  path dead in ritma-app — see classification §I).
- SpO2 rolling: mean of last 30 nightly means, shrinkage vs prior 96.
- Steps: peak per day; median of last 30 days, shrinkage vs demographic prior.
- Bedtime: median of normalized bedtimes, sample stddev (n−1), 21 nights.
- Duration: median of rounded sleeping minutes, 21 nights.
- HRV: mean + ln-sample-stddev over 21 days incl. anchor day (stress).
Architecture supports (but does NOT invent): rolling windows parameterization,
min-observation counts, missing-day skipping, timezone-aware daily boundaries,
versioned snapshots.

## 8. Idempotency & recalculation (Phases 13–15)

- Idempotency key: `(person_id, day, formula_key, version, input_digest)`.
  `input_digest` = sha256 over the raw inputs actually consumed
  (measurement timestamps+values+night segments). Re-running with identical
  inputs UPSERTS (no duplicates).
- Recalculation boundaries (dependency-driven):
  - New night segments / HR / HRV / SpO2 for day D → recompute night summary D
    → sleep score D → readiness D → activity D. Also touch D's RHR/SpO2
    baselines IF D is inside another day's 30-night window → cascade to those
    days' readiness (bounded: readiness of D+1..D+30 at most).
  - New steps for D → steps baseline (30d window) → activity D (and future
    days' goals via auto-update job).
  - Late-arriving data for D−k (k ≤ 4) → sleep history / fatigue of D change
    → readiness D.
  - Auto-update (goals) is a SEPARATE maintenance job (cooldown/manual
    override prefs are wall-clock state, not per-day state).
- Recommend: recompute the anchor day + its dependents on write; run a nightly
  batch for baseline drift.

## 9. Explanation engine (Phase 12)

Expose ONLY components proven in ritma-app:

```json
{
  "score": 78,
  "formula": "readiness",
  "version": 1,
  "components": [
    {"key": "sleep",     "raw_value": 87.0, "normalized_value": 87, "weight": 0.35, "present": true},
    {"key": "recovery",  "raw_value": 60.0, "normalized_value": 60, "weight": 0.25, "present": true},
    {"key": "rhr",       "raw_value": 62.0, "normalized_value": 100, "weight": 0.15, "present": true},
    {"key": "spo2",      "raw_value": 95.2, "normalized_value": 63, "weight": 0.10, "present": true},
    {"key": "fatigue",   "raw_value": 78.0, "normalized_value": 78, "weight": 0.15, "present": true}
  ],
  "codes": {"cap": "none", "sleep_msg1": 0, "sleep_msg2": 1, "sleep_msg3": 3},
  "calculated_at": "2026-08-10T03:00:00-03:00"
}
```

Plus the sleep analysis codes (msg1/msg2/msg3) and stress metadata
(downCount, baselineMs, instantHrvMs). NO medical interpretation is invented.

## 10. API contract (Phase 16) — proposed, not deployed

Reuse the existing DailyScore contract from noana-wellness-app
(lib/shared/models/score.dart) — it already mirrors the backend serializers:

```
GET  /v1/wellness/scores/daily/latest/
GET  /v1/wellness/scores/daily/?from=&to=
PUT  /v1/wellness/scores/daily/{date}/      # idempotent upsert
GET  /v1/wellness/scores/daily/{date}/detail/   # breakdown + components
GET  /v1/wellness/scores/baselines/         # current baselines + confidence
POST /v1/wellness/scores/recalculate/{date}/  # admin: dependency-based recalc
```

DailyScore fields: sleep, readiness, stress_trend, stress_instant, activity,
strain (NULL — no formula), strain_target_pct (NULL), physical_capacity (NULL),
formula_version ("ritma-go-1.0.0"), computed_by ("engine"),
source_device_id, computed_at.
Formula/config administration endpoints are INTERNAL-only (admin auth), never
public.

## 11. Performance & observability (Phases 17–18)

- Benchmark targets (once implemented): one user/day << 10 ms; 30 days
  < 100 ms; 100 users/day p95 < 50 ms; 1000 users/day batch < 5 s (single
  node, no DB in the hot path for pure calc; DB cost dominated by 30-night
  window queries — index (person_id, timestamp)).
- Optimize AFTER the golden tests pass (Phase 17 rule: baseline first).
- Structured logs/counters: calculation_success, calculation_failure,
  missing_inputs{metric}, invalid_inputs{metric}, formula_version,
  calculation_duration_ms, recalculations. NEVER log raw physiological
  datasets or PII (input_digest only).

## 12. Security / medical boundary (Phase 21)

- Physiological data = sensitive: store encrypted at rest (backend already
  does), never log series, never include PII in fixtures (golden dataset is
  synthetic).
- The engine is a WELLNESS calculator. No diagnosis, no clinical thresholds
  invented; thresholds are only the ones ritma-app hardcodes.

## 13. Implementation order (Phase 10 stages — each compiles + tests)

1. **STAGE 1** domain types + units + validation + timezone handling.
2. **STAGE 2** raw metric normalization (filters, peak counter, daily means).
3. **STAGE 3** statistical utilities (medianInt semantics incl. even-n rounding,
   mean, sample stddev, P10 nearest-rank, linear-weighted mean, lerp).
4. **STAGE 4** night pipeline F-12 (gap-fill, 1h expunge, 16h cap, battery
   flag, HRV mean) — golden cases N1–N5.
5. **STAGE 5** baselines F-05/F-06/F-13/F-14 (+shrinkage, confidence).
6. **STAGE 6** sleep score F-01 (golden A.1).
7. **STAGE 7** stress F-02 (golden A.2) + instant HRV.
8. **STAGE 8** readiness F-03 (golden A.3 + B.2 pipeline).
9. **STAGE 9** activity F-04 (golden A.4) + day target/zone.
10. **STAGE 10** demographic priors F-10 (golden A.5).
11. **STAGE 11** lifestyle auto-update F-08/F-09 (guardrails, cooldowns).
12. **STAGE 12** versioning/config + config_hash.
13. **STAGE 13** explanation engine + sleep codes.
14. **STAGE 14** store interfaces + SQL schema + idempotent upserts.
15. **STAGE 15** API service (contract §10) + admin auth.
16. **STAGE 16** observability + benchmarks (Phase 17).
17. **STAGE 17** differential harness vs the Dart oracle (Phase 20) — the
    final gate: Go result == ritma-app result on the golden dataset.

## 14. Risks

1. **Timezone**: the app computes in device-local time; the backend must know
   each person's timezone (new input — NOT in ritma-app). Wrong tz → wrong
   night windows/baselines. Mitigation: explicit tz in every input; tests in
   ≥2 tz; document the behavioral change for users crossing tz. Related: the
   BACKEND's own day boundary is 03:00 local (timeseries queries) while the
   app scores on midnight — pick one canonical boundary per pipeline stage.
2. **Floating-point parity**: Dart `.round()`/`toInt()`/IEEE754 ordering must
   be replicated; the pctLight 57.99999999999999 artifact is the canary.
3. **F-01 dead coef0 path**: port as-is (dead branch preserved) until product
   confirms intent — changing it breaks parity.
4. **Filtered SpO2/HR collections**: dead in the app (no writer); if the
   backend starts writing them, F-06 behavior changes (filtered preferred).
   The Go engine should implement the filtered-first rule anyway (parity with
   the CODE, not the current data state).
5. **HRV semantics unknown** (device-computed): a firmware/SDK change on the
   band changes stress scores without any app change — monitor via
   baseline/score drift alerts.
6. **No upstream oracle for the full pipeline**: F-12/service-layer golden
   cases are hand-derived; the differential harness (Phase 20) is mandatory
   before trusting readiness end-to-end.
7. **Score 0 vs error**: 0 = no data is a product semantic; API consumers must
   not treat 0 as "worst score".
8. **Auto-update state**: cooldown/manual-override keys are wall-clock —
   backend needs equivalent state (or the feature stays client-side).
9. **HANDOFF roadmap**: strain/capacity formulas DO NOT exist — any future
   strain feature must be designed fresh (never "ported"). No heart-rate
   zones exist either (no Karvonen/220−age anywhere).
10. **SLEEP-STAGE MAPPING CONFLICT (open)**: executing mapper says raw
    1→Light/2→Deep; ingestion comment says 1=deep/2=light. Port the executing
    behavior for parity, gate behind a config flag, verify against a real
    device / JStyle official app before trusting deep/light values.
11. **Instant stress score divergence**: the UI's instant score uses
    baselineLnSd fallback 0.15 vs core 0.22 (and core clamps ≥0.20). The Go
    engine should expose instant stress ONLY via the core formula (0.22
    semantics) and flag the product decision.
12. **Two RHR definitions**: score-path P10 vs card mean-of-lowest-20%.
    Engine implements P10 (the score-path one); the card value is display.
13. **UI-only temperature baseline (21-day mean)**: no core counterpart. If
    temperature features become server-side, port F-21 (mean + deviation
    zones ±1.0/1.5 °C) as a NEW formula — it is NOT part of any score.
14. **Device-specific heuristics to document**: sport-history distance
    m-vs-km heuristic (`> 50` rule), MET defaults (70 kg, 4.0), kcal counter
    reset tolerance (+1), steps cumulative-counter semantics.

## 15. First deliverable on this branch (what this PR contains)

- docs/wellness-formula-audit.md (F-01..F-21, all constants/thresholds/windows)
- docs/wellness-formula-classification.md (Phase 2)
- docs/wellness-formula-dependencies.md (Phase 3)
- docs/wellness-input-contract.md (Phase 4)
- docs/wellness-golden-dataset.md + docs/golden/oracle.json (Phase 5,
  machine-executed from the real Dart code)
- docs/formula-configuration-decisions.md (Phase 9)
- test/golden_oracle_test.dart (the executable Dart oracle, 5/5 green)
- test/goal_oracle_test.dart (executable F-08/F-09 oracle: real
  PersonalizedLifestyleBaseline + in-memory Isar + mocked prefs, 17 cases →
  docs/golden/oracle-goals.json)
- wellness-engine/ — Go module implementing STAGES 1–13:
  - STAGES 1–8: domain + stats + night pipeline + baselines + priors + the
    four score formulas + engine orchestration + CLI (golden-tested against
    oracle.json)
  - STAGE 11: F-08/F-09 goal auto-update (internal/goals, pure, explicit
    Now; golden-tested against oracle-goals.json, incl. the provisional-
    confidence behavior)
  - STAGE 12: formula versioning + config hash (internal/versioning:
    registry, active-v1 selection, sha256 config hash)
  - STAGE 13: explanation engine (internal/explain: components, steps,
    warnings, missing reasons; recomposition tests)
  - engine.CalculateDayDetailed → CalculationBundle {Scores, Goals,
    Metadata, Explanations, Quality}; CLI `--explain`
  - STAGE 15: Postgres persistence (internal/persistence/postgres +
    internal/repository): schema 0001_init.up.sql, atomic PersistBundle,
    DB-enforced idempotency, revision model, advisory-lock concurrency,
    input fingerprint (engine.Input.Fingerprint)
  - STAGE 17: API (internal/application WellnessService + internal/
    transport/httpapi + cmd/wellness-api + api/openapi.yaml)
  - STAGE 18: differential/shadow harness (internal/differential +
    cmd/wellness-diff + test/diff_runner_test.dart): canonical fixtures,
    Go runner, comparator, case-level report accounting, fail policy,
    deterministic corpus generator, 41-fixture boundary corpus; 200-fixture
    corpus clean (0 mismatched cases). Docs: wellness-differential-testing.md,
    wellness-shadow-mode-design.md (shadow flow DESIGN ONLY).
  - STAGE 19A: HML shadow validation DESIGN (docs/wellness-hml-shadow-design.md
    + wellness-hml-input-mapping.md): real input path traced (backend Redis
    TimeSeries + hipnograma → Isar → Dart), canonical boundary defined,
    mapping with statuses, replay-then-online invocation, acceptance gates,
    Docker readiness = READY.
  - Not yet implemented: 19B containerization + HML shadow deployment,
    observability/benchmarks, Flutter/backend cutover.

## 16. Differential testing status (Phase 20)

The oracle harness (Dart) and the Go golden tests are both in-repo:
- Dart side: `flutter test test/golden_oracle_test.dart` → 5/5, writes
  docs/golden/oracle.json; `flutter test test/goal_oracle_test.dart -j 1` →
  1/1 (17 goal cases), writes docs/golden/oracle-goals.json.
- Go side: `go test ./...` → all packages green, asserting exact parity
  against oracle.json (sleep 8/8 cases, stress 6/6, readiness 8/8, activity
  6/6, baselines 2/2, priors 2/2) + hand-derived pipeline cases (N1–N5,
  B.2 readiness=78 end-to-end) + oracle-goals.json (12 steps + 5 sleep
  goal cases) + explanation recomposition tests (sleep 90, stress 40,
  readiness 78/58-capped, activity 78).
The remaining gap is the Isar-backed service layer (full readiness with
DB-driven RHR/SpO2/fatigue) — covered by hand-derived B-section cases until
STAGE 17 wires the real app execution.
