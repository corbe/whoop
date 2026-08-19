# Sleep-Stage Mapping Investigation

**Status:** OPEN — real-device verification BLOCKING before production cutover.
**Date:** 2026-08-19
**Repository:** noana-org/ritma-app @ `5b1698f` (branch `feat/go-wellness-engine`)

## The conflict

The JStyle bracelet emits raw sleep-stage values that the app maps to the
canonical set (0=Wake, −1=REM, −2=Nap, −3=Light, −4=Deep). Two sources in the
repo disagree about raw value 1 and 2:

| Source | File:line | raw 1 | raw 2 |
|---|---|---|---|
| **EXECUTING mapper** | lib/core/utils/sleep_stage_mapper.dart:18-31 (`braceletRawToCanonical`) | **Light (−3)** | **Deep (−4)** |
| Ingestion comment | lib/src/isar/db/bracelet_service.dart:768-773 ("CORRIGIDO - baseado no app oficial") | **deep** | **light** |

Both were introduced in the same port commit (3df6ddc); there is no further
history and the JStyle SDK (lib/jstyle/) passes the stage array through
without decoding (`device_key.dart:158-162` — "5-minute sleep quality, 24
values") — no third source in the repo settles it.

## Executing behavior (the oracle)

`SleepStageMapper.braceletRawToCanonical` is the ONLY code that runs
(consumed at bracelet_service.dart:1544 in `_generateSleepStages`):

```
raw 0 → Wake      raw 1 → Light      raw 2 → Deep      raw 3 → REM      other → Wake
```

If the comment is right (1=deep, 2=light), then pctDeep and pctLight are
SWAPPED downstream for every user:
- sleep score stage-quality discount (penalizes LOW deep and LOW rem) would
  run on swapped values;
- stage % panels and charts (sleep_score_breakdown_panel, sleep_stage_graph)
  would show inverted deep/light;
- sleep duration baselines are unaffected (duration is stage-agnostic).

## Downstream impact map (if the comment is right)

| Consumer | Impact |
|---|---|
| F-01 quality discount (sleep_score.dart:151-157) | discount computed on wrong stage % |
| F-12 stage sums (sleep_stage_summary.dart:109-129) | light/deep ms swapped |
| stage % display (breakdown panel, bars) | visually inverted |
| RHR/SpO2 windows, baselines | unaffected (window-based, stage-agnostic) |

## Engine boundary (what the Go engine does)

1. The scoring engine consumes ONLY canonical stages (`domain.Segment.Stage`,
   validated by `domain.ValidStage`).
2. The single raw→canonical translation point is
   `domain.BraceletRawToCanonical` (wellness-engine/internal/domain), a
   faithful port of the EXECUTING mapper — NOT the comment.
3. Tests prove the Light/Deep canonical boundary
   (`TestBraceletRawToCanonical`: raw 1 → Light, raw 2 → Deep) and that
   non-canonical stages are ignored by the night pipeline (Dart switch
   semantics).

## Verification plan (BLOCKING)

Stage 19A refined the procedure into a concrete HML-executable check (see
`docs/wellness-hml-shadow-design.md` §sleep-stage mapping verification):

1. Export one person's hipnograma segments (raw stage ints + timestamps) for
   one night — these are the SAME raw ints the app stores (`deviceSource
   'API'`, no remapping at ingest).
2. Export the same night's SDK-labeled stages (`deviceSource 'BRACELET'`,
   `bracelet_service.dart` writes these) — the SDK path is the one the
   ingestion comment describes.
3. Compare per segment: SDK label vs raw int. 1→Light/2→Deep (executing
   mapper) is correct iff SDK labels raw 1 as Light and raw 2 as Deep.
4. Cross-check the app's sleep card stage-minute counts against both.

- [ ] Run the above on a real J2208 band / JStyle app session (HML).
- [ ] Confirm with the SDK vendor the meaning of values 0..3 in
      `arraySleepQuality`.
- [ ] If the comment is right: flip `BraceletRawToCanonical` behind a config
      flag (formula version bump for `sleep`), re-run the golden dataset
      (stage inputs are canonical, so only the ingestion mapping changes),
      and ship with a documented behavioral change.
- [ ] Until verified: the engine KEEPS the executing mapper (parity).

## UNKNOWNs (not guessed)

- Which mapping the device actually emits (needs hardware).
- Whether the "CORRIGIDO" comment reflects a device firmware variant.
- Whether any historical user data was scored under a swapped mapping (the
  app has been in TestFlight/Internal testing; no migration exists).
