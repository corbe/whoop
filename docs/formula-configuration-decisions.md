# Formula Configuration Decisions — ritma-app → Go engine

**Rule:** a value is CONFIGURABLE only if the Dart code already treats it as a
calibration/parameter (injectable) OR product explicitly asks for it. Everything
else is HARDCODED ALGORITHM (structure) and stays in Go code. Rationale for
every decision below.

## 1. Configurable parameters (moved to DB/config with versioning)

These already exist as injectable calibration objects in Dart
(lib/core/scores/score_calibration.dart) — moving them to config is parity, not
new flexibility:

| Group | Parameter | Dart default | Decision |
|---|---|---|---|
| Sleep | defaultBedTimeMinutes | 1320 | CONFIG (PersonalizedBaselineCalibration also mirrors it) |
| Sleep | defaultSleepTargetMinutes | 480 | CONFIG |
| Sleep | onTimeThresholdMin | 30 | CONFIG |
| Sleep | somewhatThresholdMin | 90 | CONFIG |
| Sleep | maxBedTimeDiscount | 15 | CONFIG |
| Sleep | maxDurationDiscount | 65 | CONFIG |
| Sleep | bedLateCoef1 / bedLateCoef2 | 0.0899 / 0.1333 | CONFIG |
| Sleep | earlyCoefLight / earlyCoefHeavy | 0.3 / 0.65 | CONFIG (see dead-path note §3) |
| Sleep | durationOverCoefLight / Heavy | 0.4 / 0.75 | CONFIG |
| Sleep | durationCoef1/2/3 | 0.25 / 0.2666 / 0.2777 | CONFIG |
| Stress | defaultLnSd | 0.22 | CONFIG |
| Stress | minLnSd / maxLnSd | 0.20 / 0.40 | CONFIG |
| Stress | zClampMin / zClampMax | −1.0 / 3.0 | CONFIG |
| Stress | minScoreWithData | 12.0 | CONFIG |
| Stress | baselineWindowDays | 21 | CONFIG |
| Stress | minDaysRequired | 5 | CONFIG |
| Stress | rollingTrendDays | 7 | CONFIG |
| Stress | instantWindowMinutes | [15,60,180] | CONFIG |
| Stress | sigmoidMidpoint / Steepness / Span | 2.0 / 0.72 / 83.0 | CONFIG |
| Readiness | weightSleep/Recovery/Rhr/Spo2/Fatigue | .35/.25/.15/.10/.15 | CONFIG |
| Readiness | sleepTodayWeight / sleepHistoryWeight | .70 / .30 | CONFIG |
| Readiness | fatigueIdentityThreshold | 65 | CONFIG |
| Readiness | rhrZeroRatio | 1.12 | CONFIG |
| Readiness | fatigueLookbackDays | 3 | CONFIG |
| Readiness | sleepHistoryDays | 4 | CONFIG |
| Readiness | capSleep30/40/50/60 | 35/45/58/72 | CONFIG |
| Activity | defaultGoalSteps | 7000 | CONFIG |
| Activity | kcalPerStep | 0.04 | CONFIG |
| Activity | minGoalKcal / maxGoalKcal | 150 / 800 | CONFIG |
| Activity | dayTargetReadinessWeight | 0.55 | CONFIG |
| Activity | dayTargetNeutral | 55 | CONFIG |
| Activity | dayTargetMin / dayTargetMax | 30 / 90 | CONFIG |
| Personalized | stepsWindowDays | 30 | CONFIG |
| Personalized | sleepWindowDays | 21 | CONFIG |
| Personalized | autoUpdateCooldownDays | 7 | CONFIG |
| Personalized | manualOverrideBlockDays | 30 | CONFIG |
| Personalized | maxStepsChangeFraction | 0.35 | CONFIG |
| Personalized | maxBedtimeChangeMinutes | 30 | CONFIG |
| Personalized | maxSleepTargetChangeMinutes | 30 | CONFIG |
| Personalized | minConfidenceForAutoUpdate | good (index 2) | CONFIG |
| Personalized | baseDailySteps / minDailySteps / maxDailySteps | 7000/3000/15000 | CONFIG |
| Personalized | min/maxSleepTargetMinutes | 300/600 | CONFIG |
| Baseline | priorRestingHrBpm | 65.0 | CONFIG (hardcoded const in Dart) |
| Baseline | priorNightSpo2Pct | 96.0 | CONFIG (hardcoded const) |
| Baseline | windowDays | 30 | CONFIG (hardcoded const) |
| Baseline | sleepBaselineWindowDays | 21 | CONFIG (hardcoded const) |

Note: several "hardcoded const" Dart values (priors, window sizes) are
converted to CONFIG in Go because they are exactly the kind of product-tuning
knobs versioning exists for; the initial config ships with the Dart defaults
unchanged.

## 2. HARDCODED ALGORITHM (structure — stays in Go code, versioned by release)

| Item | Why |
|---|---|
| F-01 discount model (100 − discounts) | algorithm structure |
| F-01 diff wrap ±720 min | structure |
| F-01 `.toInt()` truncation of discount sum | rounding semantics (parity) |
| F-02 ln domain, lnRmssd, sample-stddev n−1 | structure |
| F-02 z = −0.4 short-circuit at observed ≥ 2×baseline | structure (not a threshold param in Dart) |
| F-02 sigmoid shape (logistic) | structure |
| F-02 sanitize clamp ±45%..+55% | structure (0.45/1.55 hardcoded in code) |
| F-03 weightedBlend renormalization | structure |
| F-03 caps applied as min() (never raise) | structure |
| F-03 P10 nearest-rank, median even-n averaging, ceil/round choices | statistical semantics (parity) |
| F-04 steps = PEAK of cumulative counter | device semantic (parity) |
| F-04 round-to-nearest-10, clamps | structure |
| F-12 night window [18:00, 12:00] | structure (calibration has nightStart/EndHour but they're DEAD — code hardcodes 18/12; see §3) |
| F-12 gap-fill as Wake, 1h expunge rule, 16h cap, battery <3.0 flag | structure |
| F-12 stage encoding 0/−1/−2/−3/−4 | data contract |
| F-13 normalized-bedtime (+1440 if < 720) | structure |
| F-08/09 quarter-hour rounding, guardrail order | structure |
| F-10 age/BMI/gender rules | structure (rules, not numbers — but numbers ARE the config above) |
| HR filter 30<x<220, SpO2 filter 70≤x≤100 | validity semantics (parity) |
| Sleep analysis codes msg1/msg2/msg3 | explanation contract |

## 3. Dead Dart parameters — NOT ported as config

Verified repo-wide (no `cal.<param>` / `_cal.<param>` reads outside
score_calibration.dart):

| Parameter | Declared default | Verdict |
|---|---|---|
| StressScoreCalibration.instantFallbackHours | 24 | OMIT (never used; instant window list [15,60,180] is the real behavior) |
| SleepScoreCalibration.idealStagePctMin/Max | 20/25 | OMIT as algorithm input; the values reappear HARDCODED in the breakdown panel (display). If product later wants ideal-stage scoring, design fresh. |
| SleepScoreCalibration.highStagePct | 30 | OMIT (never used) |
| SleepScoreCalibration.batteryDepletedPct | 3.0 | OMIT as config — the flag uses the HARDCODED `< 3.0` (sleep_stage_summary.dart:161). Port the hardcode; document. |
| SleepScoreCalibration.nightStartHour/nightEndHour | 18/12 | OMIT as config — code hardcodes 18:00/12:00 (sleep_stage_summary.dart:216-219). Port hardcoded; if product wants configurability, introduce LATER as a real feature. |
| ReadinessScoreCalibration.rhrBaselineWindowDays | 21 | OMIT — baseline uses hardcoded 30 (wellness_baselines.dart:23,117). Port 30. |

Rationale for omission: porting dead config would create config entries with
no effect (liability: operators tune them, nothing changes).

## 4. Cross-cutting decisions

1. **Calibration defaults = parity anchor.** The Go engine's v1 config MUST
   equal `ScoreCalibration.current` defaults exactly (they are the golden
   dataset's implicit config). Any future tuning ships as formula_version 2
   with its own config row.
2. **Config granularity.** One config row per formula version (JSONB
   parameters) — NOT per-parameter tables. Matches the Dart design (one
   calibration object per score).
3. **Config validation.** On load: unknown keys rejected; ranges validated
   (weights sum sanity 0–1.5, windows ≥ 1, thresholds monotonic where
   required). A bad config fails loudly (engine refuses to calculate), never
   silently falls back.
4. **No DSL.** ritma-app proves no need for executable formula definitions;
   structure is code, numbers are data. Revisit ONLY if product demands
   operator-authored formulas (not currently a requirement).
5. **Hardcoded device semantics stay documented** in the input contract
   (steps peak, HRV device-computed, SpO2 filtered-first rule with the
   no-writer caveat).

## 5. Stage 11–13 additions

6. **Goal config (F-08/F-09) is CONFIGURABLE** (internal/goals.Config): the
   Dart code reads these from `ScoreCalibration.current.personalized`, so
   stepsWindow/sleepWindow/cooldown/override-block/max-change-fraction/delta
   caps/min-max clamps all get typed fields with parity defaults. The
   minConfidenceForAutoUpdate default is **2 (provisional.index)** — the
   CODE default, not the stale "good" comment (see audit F-08).
7. **Config hash.** Every result records `config_hash = sha256(typed config
   structs)` (internal/versioning.HashConfig). Participation = all six typed
   configs; serialization = declaration order, 'g' float format, quoted
   strings, order-sensitive slices; excludes engine_version/calculated_at.
   Changing any weight/threshold/window → new hash → historical results stay
   reproducible under their recorded hash.
8. **Versioning.** All six formulas (sleep/stress/readiness/activity/
   goal_steps/goal_sleep) are v1 ACTIVE in one centralized registry
   (versioning.DefaultRegistry). No per-file version literals. DB-backed
   registry replaces it later without touching the calculation core.
