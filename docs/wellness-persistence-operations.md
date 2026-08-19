# Wellness Persistence — Operations Notes (STAGE 15)

Concise operator-facing facts. Full design: docs/wellness-persistence-design.md.

## Connection / setup

- Module: `wellness-engine/`; adapters in `internal/persistence/postgres`.
- Apply schema: `postgres.Migrate(ctx, pool)` (embedded SQL files under
  `internal/persistence/migrations`, tracked in `schema_migrations`,
  idempotent). No CLI/API yet — call from code or `go test`.
- Seed formula registry once: `Store.SeedFormulaVersions(ctx, paramsJSON)`
  (parity v1 rows; ON CONFLICT DO NOTHING).

## Write path

```
engine.CalculateDayDetailed(in, cfg) → bundle
persistence.ProjectBundle(in, bundle) → repository.Input + Bundle
store.PersistBundle(ctx, input, bundle)
```

- One transaction per bundle. `repository.ErrDuplicateRun` = idempotent
  replay (same person/day/fingerprint/config/engine) — nothing written.
- New input/config/version → new run, `replaces_run_id` chain, old rows
  stay immutable (is_current flips).
- Concurrent writers for the same person/day are serialized by a Postgres
  advisory xact lock (last writer wins); no app locks needed.

## Observability hooks (for STAGE 18)

- `ErrDuplicateRun` — idempotent replay counter.
- run created vs replay: `PersistBundle` returns the run + sentinel error;
  callers distinguish by `errors.Is(err, repository.ErrDuplicateRun)`.
- `ErrInvalidFormulaVersion{Key, Version}` — bundle referenced a version not
  registered ACTIVE.
- Transaction failures wrap as `persist bundle: <cause>` (rollback verified
  by `TestTransactionRollback`).
- Never log raw physiological payloads; explanation JSONB is already
  derived data.

## Retention

No deletion implemented. Categories + policy durations are a PRODUCT/LEGAL
decision (LGPD) — see design doc §12.

## Test database

- `TEST_DATABASE_URL` env, else Docker `postgres:16-alpine` (skipped if no
  Docker). Tests truncate their tables per test — never point this at a
  shared/dev DB with real data.
