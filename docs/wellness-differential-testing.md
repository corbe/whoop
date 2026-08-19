# Wellness Engine — Differential (Dart vs Go) Validation

**Stage 18.** A harness that executes the SAME canonical input through the real
production Dart implementation and the Go engine, compares every comparable
output field, and reports mismatches with explicit classification and a strict
fail policy. The Dart implementation is the compatibility oracle; the Go
engine must never influence production/user-visible scores during validation.

## Layout

- `wellness-engine/internal/differential/` — canonical fixture format, Go
  runner (`engine.CalculateDayDetailed`, no HTTP), comparator, report writer,
  fail policy, deterministic synthetic generator, Dart runner invoker.
- `wellness-engine/cmd/wellness-diff/` — CLI:
  - `wellness-diff --generate N [--seed S]` → deterministic corpus
  - `wellness-diff --fixtures-dir DIR [--dart]` → Go-only or full Dart-vs-Go
  - writes `differential-report.json` + `differential-summary.txt`;
    exit 1 when mismatched cases > 0 (unless `--no-fail`)
- `test/diff_runner_test.dart` — the Dart oracle runner: seeds an in-memory
  Isar from canonical fixtures and executes the REAL production services
  (`SleepScoreService`, `StressScoreService`, `ReadinessScoreService`,
  `ActivityScoreService`, `PersonalizedLifestyleBaseline`) in ring order.
  Requires `DIFF_FIXTURES_DIR` + `DIFF_OUT_DIR` (set by the CLI). Runs in the
  HOST local timezone — fixtures must declare it (the generator emits
  `time.Local.String()`; the loader refuses mismatches).
- `wellness-engine/testdata/differential/` — 41-fixture boundary corpus
  (awake-gap / capped / empty / stage-varied anchors × goals × battery).

## Canonical fixture format

One sanitized person-day (synthetic `person_id`, no PII), same wire family as
the CLI/API inputs. Single segment source: `baseline_nights` (30 nights
anchored at D-1..D-30; `[0]` = the night before the anchor day) plus
`segments` (the anchor night, day D). Raw HRV/HR/SpO2 samples carry
timestamps; the Go runner buckets HRV by local dayKey exactly like the Dart
services; RHR/SpO2 baselines are inputs to Go and are seeded in Dart so the
DB-derived baselines match by construction (see below).

## Seeding semantics discovered (Dart quirks, all mirrored by the harness)

- **Isar `SleepStageRecord.id = fastHash(personUuid_startTs)`** — records with
  duplicate start timestamps silently overwrite each other. Never seed the
  same night twice; one night = one segment source.
- **Night templates must be anchored per night** — absolute timestamps leak
  into other nights' windows. Bedtimes after midnight (e.g. 00:30) belong to
  the anchor day itself; a D-1 offset puts them before the window and
  `_loadRawSegments` drops them (`startTsGreaterThan(nightStart-1)`).
- **`_discardBeforeLongAwakeGap`** — finds the FIRST continuous Wake run
  (filled gaps included) ≥ 1h; `>=` is inclusive; keeps the side with MORE
  real sleep (`after >= before ? after : before` — tie keeps AFTER); runs
  again after the first pass. Wake runs < 1h stay as Wake; sleeping/wake are
  both counted from the kept window.
- **Sleep score inputs** — the duration discount uses `sleepingTime`; stage
  percentages use `pctRem/pctDeep/pctLight` over the sleeping time.
- **Goals run BEFORE day scores** (`maybeAutoUpdateAll`), so the effective
  bedtime/sleep-target (and steps goal) used by the day's scores are the
  POST-UPDATE values. The readiness history is recomputed with the same
  updated config — fixture `sleep_history` must be derived from the
  goal-effective bed/target (the generator does this via `goals.UpdateSleep`).
- **`ensureSeededDefaults`** seeds 1320/480 into prefs before the sleep-goal
  check — the "current" config is NEVER null; zero-delta updates are
  suppressed (`unchanged` check) and reported as `updated: false, nulls`.
- **`SharedPreferences` is a singleton** across fixtures — the runner wipes
  every production-read key per fixture.
- **Activity sessions have NO person ownership** — `_sessionKcalForDay` filters
  by `status == 'completed'` + `startTime` in the day only; the runner wipes
  ALL sessions between fixtures.
- **RHR/SpO2 baselines are DB-derived in Dart** — `nightlyRestingHr` requires
  a non-empty `forNight` summary AND HR samples inside the summary window;
  `rollingRestingHr` iterates D-1..D-30 with `windowDays = 30`; empty or
  capped nights (degenerate `[18:00,18:00]` window) contribute nothing. The
  generator seeds identical per-night patterns and DERIVES the fixture's
  baseline inputs from the contributing-night count via the same shrinkage
  blend (priors 65 bpm / 96%). Capped anchors cannot yield RHR/SpO2 in Dart —
  the generator omits those inputs for them. The Dart P10 = `sorted[floor(0.1n)]`
  with n=10 → fillers must be strictly greater than the target.

## Comparison semantics

- Integers, booleans, strings (status/categorical): EXACT.
- Floats (stress baseline/instant HRV tails): tolerance 1e-9 ABS; a delta
  within tolerance is `ROUNDING_ONLY` (expected; these are identical IEEE-754
  computations serialized with different digit counts). Never loosened.
- Fields are COMPARABLE only; metadata one side lacks is not emitted.
- Classification: `EXACT_MATCH`, `ROUNDING_ONLY`,
  `EXPECTED_IMPLEMENTATION_METADATA`, `INPUT_NORMALIZATION_DIFFERENCE`,
  `BASELINE_DIFFERENCE`, `GOAL_DIFFERENCE`, `INTERMEDIATE_DIFFERENCE`,
  `FINAL_SCORE_DIFFERENCE`, `MISSING_DATA_DIFFERENCE`, `QUALITY_FLAG_DIFFERENCE`,
  `UNKNOWN`. Unknown is never auto-fixed.

## Report accounting (case-level)

One case (fixture) is exactly one of: `EXACT` (0 mismatches),
`EXPECTED_ONLY` (only expected-class mismatches), `MISMATCHED` (≥ 1
unexplained). Invariant: exact + expected_only + mismatched == total_cases.
Fields are counted separately (`total_mismatch_fields`, expected/unexplained
split). `MISMATCHED_CASES` drives the fail policy; `MAX_SCORE_DELTA` covers
final/intermediate numeric deltas.

## Fail policy (CI)

Fail on: `FINAL_SCORE_DIFFERENCE`, `UNKNOWN`, unexpected baseline/goal
difference, missing-data semantic difference, quality-flag difference, and
any unexplained intermediate difference. Only `ROUNDING_ONLY` (and
`EXPECTED_IMPLEMENTATION_METADATA` when a field is whitelisted) pass.

## Current results

Deterministic 200-fixture corpus (seed 42) + 41-fixture boundary corpus:
`MISMATCHED CASES = 0`, `UNEXPLAINED FIELDS = 0`, `FINAL_SCORE_DIFFERENCE = 0`,
`MAX SCORE DELTA = 0`. Remaining differences are 1e-15 float serialization
tails (`ROUNDING_ONLY`). B.2 through the harness: sleep 90 / stress 40 /
readiness 78 / activity 78.

## Performance (informational)

200 fixtures: Dart ≈ 60–95 s (per-fixture Isar + prefs setup), Go ≈ 15 ms,
comparison ≈ 6 ms.

## Privacy

Synthetic person IDs only; reports carry no names/emails/tokens/identifiers.
Future real-data runs must hash/pseudonymize identity (see shadow-mode doc).
