# Formula Versioning — RITMA Go Wellness Engine

**Status:** implemented (STAGE 12) in `wellness-engine/internal/versioning`.
**No persistence yet:** the registry is in-memory; a database-backed registry
replaces selection later without touching the calculation core.

## Formula identities (stable keys)

Keys map 1:1 to audit formulas (no invented identities):

| Key | Audit ID | Name |
|---|---|---|
| `sleep` | F-01 | Sleep Score (discount model) |
| `stress` | F-02 | Stress Score (HRV log-domain sigmoid) |
| `readiness` | F-03 | Readiness Score (weighted blend + caps) |
| `activity` | F-04 | Activity Score (kcal goal) |
| `goal_steps` | F-08 | Steps Goal Auto-Update |
| `goal_sleep` | F-09 | Sleep Config Auto-Update (bedtime + target) |

## Version structure

```go
type FormulaVersion struct {
    Key           Key
    Version       int
    Status        Status   // DRAFT | ACTIVE | RETIRED
    Name          string
    Description   string
    EffectiveFrom time.Time
}
```

- Status lifecycle: DRAFT → ACTIVE → RETIRED. The registry resolves the
  highest-versioned ACTIVE entry per key.
- No executable code is stored anywhere; versions identify *which code +
  which parameters* produced a result. Algorithm structure is versioned by
  the Go release; parameters by the config hash.

## Active/default version (centralized)

`versioning.DefaultRegistry()` is the SINGLE place that defines the active
version (currently v1 for all six formulas, ACTIVE, effective 2026-08-19).
No `Version: 1` literals are scattered in the scoring code. Future persistence
(STAGE 14+) replaces `DefaultRegistry()` with a DB-backed registry without
rewriting the calculation core.

## Result metadata contract

Every `CalculationBundle` exposes:

```json
{
  "formula": "readiness",
  "formula_version": 1,
  "config_hash": "sha256:<64 hex>",
  "engine_version": "dev",
  "calculated_at": "<explicit Now input>"
}
```

- `calculated_at` is metadata ONLY — it never influences `config_hash` or the
  mathematical output (the engine requires an explicit `Now` input; the
  deterministic path defaults it to the anchor date).
- `engine_version` is build-injected via ldflags
  (`-X .../versioning.EngineVersion=v1.2.3`); defaults to `dev`; never
  hardcoded as a Git SHA.

## Config hash (deterministic)

`versioning.HashConfig(ConfigSet)` → `sha256:<hex>` over the SEMANTIC config
values of all six config structs (sleep, stress, readiness, activity,
baseline, goals).

### What participates

Every typed field of the six config structs (`config.Sleep`, `config.Stress`,
`config.Readiness`, `config.Activity`, `config.Baseline`, `goals.Config`).
The goals config participates because F-08/F-09 thresholds change goal
outputs, which transitively change the goals the scores consume.

### Serialization rules

1. Struct fields are emitted in DECLARATION ORDER (reflect order is
   deterministic for a fixed type).
2. Floats: `strconv.FormatFloat(v, 'g', -1, 64)` — deterministic for the same
   IEEE754 bits (0.10 and 0.1 hash identically).
3. Ints: base-10. Bools: `t`/`f`. Strings: `strconv.Quote`.
4. Slices: `[a,b,c]` — ORDER MATTERS (instant windows are ordered semantics).
5. Pointers: `nil` or `*value`.

### What does NOT participate

- Engine version, calculated_at (not inputs to the hash — structurally
  excluded).
- Go map iteration order (no maps in the config types), memory addresses,
  JSON formatting.

### Versioning rules

- Any parameter change (weight, threshold, window, clamp, min-sample) → new
  hash → the result is NOT reproducible under the old `config_hash`.
- A formula's *structure* change → new Go release + `engine_version`; if it
  changes parameter semantics, a new formula version (v2) with its own
  config row is the migration path.

## Reproducibility guarantee

`input + formula_version + config_hash + engine_version` fully identifies the
calculation. Same values → same result (verified by the golden tests:
`TestHashDeterministicSameConfig`, `TestHashWeightChange`,
`TestHashThresholdChange`, `TestHashSliceOrderMatters`,
`TestHashExcludesRuntimeMetadata`, `TestRegistry`).
