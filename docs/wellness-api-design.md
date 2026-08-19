# Wellness Engine — API Design (STAGE 16) + Implementation (STAGE 17)

**Status:** STAGE 16 design COMPLETE → **STAGE 17 implemented** on
`feat/go-wellness-engine`: application service (`internal/application`),
HTTP transport (`internal/transport/httpapi`, net/http ServeMux Go 1.22
patterns, no framework), DTOs, error envelope, auth boundary, health/ready,
runnable `cmd/wellness-api`, OpenAPI at `api/openapi.yaml`.
**Not deployed; no Flutter integration; no shadow mode.**

## 0. Scope & principles

- HTTP/JSON (REST) only — no gRPC. Single-day calculation is sub-millisecond
  in the pure engine, so the API is synchronous.
- Thin handlers: parse → resolve raw inputs → `engine.CalculateDayDetailed`
  → `store.PersistBundle` → map response. No business logic in handlers.
- The pure engine and the persistence layer are untouched by this design
  (dependency direction: api → engine, api → repository).
- Formula/config administration is INTERNAL ONLY (never public).
- Every response carrying a score also carries `formula_version`,
  `config_hash`, `engine_version` (reproducibility, STAGE 12).

## 1. Raw-input boundary

Two integration shapes (both supported by the same handler interface):

- **A — backend owns raw data (recommended):** the handler receives
  `person_id + date` and resolves the engine.Input through a
  `RawInputProvider` implemented against the canonical raw store (Isar today
  / future raw-data service). No raw payload crosses the wire.
- **B — stateless service:** the client posts the raw inputs (same schema as
  the CLI `--explain` input JSON). Used for differential testing and
  one-off calculations.

```go
// internal/api (design; implementation later)
type RawInputProvider interface {
    // Resolve returns the engine.Input for a person/day from canonical raw
    // storage (device-local timezone semantics; document the tz!).
    Resolve(ctx context.Context, personID string, day time.Time) (engine.Input, error)
}
```

## 2. Endpoints

### POST /v1/wellness/days/{date}/calculate

Calculate (and persist) one person-day. Auth: user-scoped (person_id from
the authenticated subject).

Request (shape A — `RawInputProvider` used):
```json
{ "person_id": "u1", "date": "2026-08-10" }
```
Request (shape B — raw inputs, same fields as the CLI input JSON, omitted
here for brevity; see wellness-engine/testdata/example-day.json).

Response 201 (new revision) / 200 (idempotent replay — same
person/day/fingerprint/config/engine already persisted; body identical,
`replay: true`):
```json
{
  "person_id": "u1",
  "date": "2026-08-10",
  "timezone": "America/Sao_Paulo",
  "replay": false,
  "run_id": 42,
  "replaces_run_id": null,
  "input_fingerprint": "sha256:...",
  "config_hash": "sha256:bbf26e9d...",
  "engine_version": "dev",
  "scores": {
    "sleep":     {"score": 90, "formula_version": 1},
    "stress":    {"score": 40, "formula_version": 1},
    "readiness": {"score": 78, "formula_version": 1},
    "activity":  {"score": 78, "formula_version": 1}
  },
  "goal_updates": [
    {"goal_key": "goal_steps", "value": 9000, "reason": "applied", "source": "auto"}
  ],
  "quality": {"warnings": [], "missing": []}
}
```

Semantics:
- Idempotency is SERVER-side and fingerprint-based (STAGE 15): retrying the
  same semantic input returns 200 + `replay: true` + the same run_id.
  No client idempotency key required; if the caller supplies
  `Idempotency-Key`, it is logged/returned for tracing only.
- New relevant input (new fingerprint), config (new hash) or formula version
  → new run, `replaces_run_id` set, scores superseded (STAGE 15 revisions).

### GET /v1/wellness/days/{date}/scores

Current scores for the day (all four formulas present; null when gated).
```json
{
  "person_id": "u1", "date": "2026-08-10",
  "config_hash": "sha256:...", "engine_version": "dev",
  "scores": {
    "sleep":     {"score": 90, "formula_version": 1},
    "stress":    {"score": 40, "formula_version": 1},
    "readiness": {"score": 78, "formula_version": 1},
    "activity":  {"score": 78, "formula_version": 1}
  }
}
```

### GET /v1/wellness/days/{date}/scores/{formula}

Score + full machine-readable explanation (STAGE 13 payload:
components/steps/warnings/missing). 404 when the formula has no current
score for that day.
```json
{
  "person_id": "u1", "date": "2026-08-10",
  "formula": "readiness", "formula_version": 1,
  "config_hash": "sha256:...", "engine_version": "dev",
  "score": 78,
  "components": [
    {"key": "sleep",    "normalized_value": 87, "weight": 0.35, "contribution": 30.45},
    {"key": "recovery", "normalized_value": 60, "weight": 0.25, "contribution": 15.0},
    {"key": "rhr",      "normalized_value": 100, "weight": 0.15, "contribution": 15.0,
     "raw_value": 62.0, "baseline_value": 64.67},
    {"key": "spo2",     "normalized_value": 63, "weight": 0.10, "contribution": 6.3,
     "raw_value": 95.2, "baseline_value": 96.07},
    {"key": "fatigue",  "normalized_value": 78, "weight": 0.15, "contribution": 11.7}
  ]
}
```

### GET /v1/wellness/days/{date}/scores/{formula}/history

All revisions, newest first: each with run_id, is_current, score, config_hash,
input_fingerprint (truncated), explanation. Historical rows are immutable.

### GET /v1/wellness/goals/current

```json
{"person_id": "u1", "goal_key": "goal_steps", "value": 9000,
 "reason": "applied", "source": "auto", "applied_at": "2026-08-10T12:00:00Z",
 "formula_version": 1, "config_hash": "sha256:..."}
```
### GET /v1/wellness/goals/history

All goal changes, newest first (append-only).

### GET /v1/wellness/baseline/current

Newest baseline snapshot (JSONB metrics as stored — no raw streams).

## 3. Internal (admin) API — NEVER public

`/internal/v1/formulas` (GET): all formula keys/versions/status.
`/internal/v1/formulas/{key}/activate` (POST, body: version): activates a
DRAFT/RETIRED version, retiring the current one (atomic: one tx; the
partial ACTIVE unique index enforces exactly one). Requires internal
service auth (mTLS or service token) — no user-facing route prefix.

## 4. Auth & authorization

- User endpoints: subject → person_id enforced server-side (JWT claim or
  gateway-injected header). A user may only read/calculate their own data.
- Admin endpoints: internal-only auth; formula/config administration is
  NEVER exposed to app clients.

## 5. Errors

| Code | Meaning |
|---|---|
| 400 | invalid input (bad date, unknown formula key, invalid timezone) |
| 401/403 | unauthenticated / not owner or not internal |
| 404 | no current score / no run for the day |
| 422 | calculation ran but produced no scores (all gated/insufficient — body carries quality.missing reason codes) |
| 409 | concurrent write conflict (retryable; normally prevented by advisory-lock serialization) |
| 500 | engine/repository failure (never exposes raw physiological data) |

Error body: `{"error": {"code": "...", "message": "...", "quality": {...}}}`.

## 6. Handler structure (implementation sketch)

```
internal/api/
  router.go      (net/http or chi; /v1/... + /internal/v1/...)
  handlers.go    (thin: parse → provider/engine/repository → respond)
  middleware.go  (authn, request-id, panic→500, no sensitive logging)
  dto.go         (request/response types — JSON tags per examples)
```
`CalculationHandler` dependencies: `RawInputProvider`, `engine` (pure),
`repository.Store`, `versioning.Registry` (or `RegistryStore` for admin).

## 7. Observability hooks (STAGE 18 ready)

Handler-level metrics: calculate_requests{result: created|replay|error},
revision_created, transaction_failed, invalid_formula_version. Never log
raw inputs or full fingerprints of non-owners; log run_id/config_hash.

## 8. Non-goals (this stage)

No deployment, no Docker/K8s, no HML/PROD wiring, no Flutter changes, no
batch/backfill API (that is a background-job stage, not REST), no formula
admin UI.
