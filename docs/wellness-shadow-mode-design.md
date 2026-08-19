# Wellness Engine — Shadow Mode Design (HML)

**Stage 18.16–18.17. DESIGN ONLY — nothing here is deployed.**

Shadow mode validates the Go engine against the live Dart implementation on
real (sanitized) HML user data before cutover, WITHOUT letting Go influence
anything user-visible.

## Flow

```
canonical physiological input (sanitized, pseudonymized person_hash)
          │
          ├────────────► current/Dart  ──► official score (unchanged path)
          │
          └────────────► Go API (shadow) ──► shadow score
                                        │
                                        ▼
                              differential comparison
                                        │
                                        ▼
                            metrics / report (observability)
```

During the shadow period the Go result MUST NOT:

- update a user-visible score
- trigger a challenge, push, or notification
- change any goal
- affect ranking or any product surface

The shadow path is read-only for the domain: it computes, compares, and
records comparison results only.

## Input pipeline (future)

- Sanitize real HML daily inputs into the canonical fixture format
  (STAGE 18.2) — same format the differential harness consumes
  (`wellness-diff --input sanitized-day.json`).
- Pseudonymize identity: `person_hash = HMAC-SHA256(secret, person_uuid)`
  truncated to 16 hex chars. No raw Cognito IDs, device tokens, or contact
  data ever reach the harness or reports.

## Shadow result model (design)

Future observability store or a dedicated table — NOT the score history
tables (those stay authoritative and un-polluted):

| field         | type    | notes                                   |
|---------------|---------|-----------------------------------------|
| person_hash   | text    | pseudonymized, no raw identifiers       |
| logical_day   | date    | anchor day                              |
| formula       | text    | sleep/stress/readiness/activity         |
| dart_score    | smallint| official (oracle) score                 |
| go_score      | smallint| shadow score                            |
| delta         | smallint| dart − go                               |
| match_status  | text    | exact / expected_only / mismatched      |
| go_run_id     | bigint  | FK to wellness_calculation_run (shadow) |
| compared_at   | timestamptz | when the comparison ran             |

No DB migration is created in this stage; the differential harness writes
`differential-report.json` locally and the shadow model above is the target
shape for the future HML observability table.

## Metrics (harness-level only)

`cases_total`, `matches_total`, `mismatches_total`, `mismatch_by_formula`,
`max_delta`, `duration`. No Prometheus/Grafana deployment in this stage.

## Concrete design

STAGE 19A produced the concrete HML architecture: real input path trace,
canonical boundary (backend timeseries APIs), field mapping, historical
windows, goal/baseline synchronization, invocation model (replay → online),
cohort, acceptance gates, storage model, observability, and the Stage 19B
contract. See `docs/wellness-hml-shadow-design.md` + `docs/wellness-hml-input-mapping.md`.

## Cutover gate

Shadow validation passes when, on a representative real-data sample,
`MISMATCHED CASES = 0` and `FINAL_SCORE_DIFFERENCE = 0` (same fail policy as
the differential harness). Known blocker that must be resolved BEFORE any
production cutover, not before shadow: the sleep-stage mapping conflict
(executing mapper 1→Light / 2→Deep vs ingestion comment claiming opposite) —
see `docs/sleep-stage-mapping-investigation.md`; PENDING REAL-DEVICE
verification, never resolved by guessing.
