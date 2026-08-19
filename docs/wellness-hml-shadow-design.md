# Wellness Engine — HML Shadow Validation Design (STAGE 19A)

**DESIGN ONLY.** Determines how the Go engine receives the SAME inputs as the
official Dart calculation in HML and is validated against it, with zero
user-visible effect. Nothing here is deployed.

## Flow

```
backend Redis TimeSeries + hipnograma (person-scoped, epoch-ms)
        │  shadow input provider (pulls D-30..D, TZ=America/Sao_Paulo)
        ▼
   CANONICAL DAY INPUT ──────► Go engine (shadow) ──► shadow result
        │                                                 │
        └────► official Dart path (unchanged) ──► official result
                                                       │
                                                       ▼
                                          differential comparison
                                                       │
                                                       ▼
                                       shadow store + metrics/report
```

The Go result never writes official tables, never triggers side effects.

## Canonical boundary (19A.2)

The backend timeseries APIs (`/person/{uuid}/{slug}/timeseries/json/` +
`/hipnograma/timeseries/json/`) are the earliest shared normalized source.
The adapter transforms backend samples → the STAGE 18 canonical fixture
(per `wellness-hml-input-mapping.md`). The Go engine receives inputs, never
official scores. App-local inputs (goals, prefs, battery, sessions,
demographics) are captured as a goal-state sidecar until the app uploads
them (mapping doc §goal state).

## Historical windows (19A.4)

One 31-day pull (D-30..D) supplies: RHR/SpO2 30-night baselines, stress 21-day
HRV baseline, F-09 sleep goals (D-1..D-21), readiness history (D-1..D-4), and
day-D activity/goal samples — the exact windows the Dart services iterate
(effectively stateless beyond 30 days). The shadow must NOT compare a
stateful Dart run against an incomplete Go history; the adapter materializes
the full window per day and fingerprints it (input_fingerprint) so runs are
idempotent and auditable.

## Goal synchronization (19A.5)

Shadow starts from the captured official goal state (steps goal, bed/target,
override/cooldown timestamps, demographics). Go may compute hypothetical
updates but writes them ONLY to the shadow store. Official goals untouched.

## Baseline synchronization (19A.6)

**Reconstruction (A)** — the Go engine derives RHR/SpO2/steps/sleep baselines
from the canonical 30/21-day inputs, exercising the full engine. This is the
preferred mode and the default. Importing (B) is NOT used unless a cohort
case proves reconstruction diverges from the app's persisted state; any such
case is documented with evidence before switching.

## Privacy / pseudonymization (19A.7)

`person_hash = HMAC-SHA256(wellness-shadow-secret, person_uuid)` truncated to
16 hex chars — stable per person, correlatable across days, irreversible
without the secret. No name/email/phone/Cognito username/device token/SNS
endpoint/wearable serial in reports, metrics, or shadow rows. No production
data in Git fixtures (cohort fixtures are synthetic or generated from
statistics only).

## Invocation model (19A.8)

**Chosen: D — replay/batch first, then online shadow.**

- PHASE A (19B): a scheduled batch validator reads the SAME canonical inputs
  the official path used (from backend storage) for historical days and
  compares — deterministic, safe, and sufficient to prove state/history
  semantics (goal/baseline windows).
- PHASE B (later): the backend calls the Go shadow synchronously after the
  official calculation for same-day inputs, with the input payload built by
  the same adapter (identical input semantics by construction).

No new infrastructure for elegance: Phase A reuses the existing wellness-diff
engine; Phase B is a POST to the existing wellness-api. Rationale: replay
isolates parity bugs from runtime issues; online shadow then proves runtime
parity only.

## Isolation rules (19A.9)

Go shadow MUST NOT: replace official scores, update official goals/baselines,
affect challenges/achievements/rankings, trigger push/chat, alter
user-visible data, or modify official wellness tables. Shadow persistence is
a separate schema/table set; the API exposes shadow endpoints under the
internal token only.

## Shadow storage (19A.10)

Logical model (no migration yet — 19B decides):
`shadow_run_id`, `person_hash`, `logical_day`, official {sleep,stress,
readiness,activity}, shadow {sleep,stress,readiness,activity}, per-formula
delta + match classification, `formula_version`, `config_hash`,
`engine_version`, `input_fingerprint`, `go_run_id`, `compared_at`.
Raw physiological streams are NOT duplicated — inputs are referenced by
fingerprint (and replayable from backend storage).

## Differential semantics (19A.11)

Reuse STAGE 18: ints EXACT; floats 1e-9 ABS; serialization tails
ROUNDING_ONLY; final-score delta of 1 IS a mismatch. No looser production
tolerance, no percentage parity.

## Validation cohort (19A.12)

Deterministic selection: take the first N (target ≥ 30) HML persons by
stable person_hash sort (not by data quality), covering: complete days,
missing-data days, low battery, short (<7d) and mature (≥30d) history,
varied sleep durations, activity/no-activity, workout/no-workout, goal
changes, varied HRV/RHR patterns, SpO2 availability. Persons with zero
wellness data are excluded (nothing to compare) and counted as
`shadow_input_missing_total`.

## Validation period (19A.13)

- PHASE A: ≥ 5 consecutive days per person (historical replay) — enough to
  exercise goal/baseline window transitions across the 7/21/30-day
  boundaries; rationale: window-state changes are the parity risk.
- PHASE B: ≥ 7 consecutive days of same-day online shadow per person —
  proves runtime parity across a full week of daily cycles. No arbitrary
  longer durations without a specific hypothesis.

## Acceptance gates (19A.14)

Across the approved cohort/window: FINAL_SCORE_MISMATCHES = 0, UNKNOWN = 0,
GOAL_SEMANTIC_MISMATCHES = 0, BASELINE_SEMANTIC_MISMATCHES = 0; plus: no
shadow side effects, no PII leakage, stable input fingerprints, no duplicate
semantic runs, no missing expected calculations. Exact final-score parity is
the target for deterministic formulas.

## Sleep-stage mapping verification (19A.15)

Procedure (runs on HML with real device data, no code change):
1. Export one person's hipnograma segment list for one night with raw stage
   ints and timestamps.
2. Export the same night from the bracelet SDK (if the wearable exposes its
   own stage labels — BRACELET vs API deviceSource records coexist in Isar).
3. Compare: for each segment, the SDK's labeled stage vs the API raw int.
   - If SDK labels raw 1 as Light and raw 2 as Deep → executing mapper
     (1→Light/2→Deep) is correct.
   - If the inverse → ingestion/mapper conflict confirmed; the executing
     mapper must change and the golden corpus regenerated.
4. Also check the app's own sleep card for one night: which stage counts
   (light/deep/REM minutes) match which raw ints.
Document findings in `docs/sleep-stage-mapping-investigation.md`. Production
cutover remains BLOCKED until resolved; shadow may proceed with raw ints.

## Failure handling (19A.16)

Shadow failures (timeout, 5xx, input load error, persist error) NEVER break
official calculation: the official path runs first/independently; shadow
errors are caught, counted (`shadow_failures_total`), and recorded with the
reason — no user-visible error, no retry storm.

## Timeout / resources (19A.17)

Shadow call: timeout 5s, no retries (replay jobs re-run naturally),
concurrency cap 4 per instance (backend resource isolation), shadow DB
connection pool separate from the official pool. No autoscaling design.
Stage 18's ~15ms/200-fixture Go timing is synthetic — not capacity proof;
replay jobs measure real per-day latency before Phase B.

## Observability (19A.18)

Metrics (future): `shadow_calculations_total`, `shadow_matches_total`,
`shadow_mismatches_total`, `shadow_failures_total`, `shadow_duration_seconds`,
`shadow_mismatch_by_formula`, `shadow_input_missing_total`. Dimensions:
formula, classification, engine_version. NEVER person_id as a label
(high-cardinality; person_hash is also excluded from labels).

## Auditability (19A.19)

Every shadow comparison answers: which input (input_fingerprint), which day,
which formula_version/config_hash/engine_version, which official result,
which Go result, what delta, when compared — without storing raw physiology.

## Stage 19B deployment contract (19A.20)

Artifacts: `wellness-api` binary (already builds), runtime config, DATABASE_URL
(shadow schema), INTERNAL_TOKEN, health/ready endpoints (already present),
input-provider dependency (backend timeseries adapter — NEW, the only
missing piece), migration for the shadow schema (pending design), no local
filesystem dependency, no embedded credentials.

Environment (proposed): `DATABASE_URL`, `SHADOW_DATABASE_URL` (or a separate
schema on the same cluster), `INTERNAL_TOKEN`, `WELLNESS_SHADOW_SECRET`
(pseudonymization), `TZ=America/Sao_Paulo`, `PORT`.

## Docker readiness (19A.21)

| check | status |
|---|---|
| API binary exists | YES (cmd/wellness-api) |
| configuration externalized | YES (env) |
| no local filesystem dependency | YES |
| migrations understood | YES (embedded MigrationsFS) |
| health/readiness | YES (/health /ready) |
| graceful shutdown requirements | KNOWN (net/http, no long-lived workers yet) |
| DB dependencies known | YES (Postgres) |
| input-provider boundary known | YES (adapter — to build in 19B) |
| no embedded HML credentials | YES |

**DOCKER_READINESS = READY** (the input-provider adapter is a code artifact of
19B, not a containerization blocker).
