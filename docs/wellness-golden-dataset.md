# Wellness Golden Dataset — ritma-app → Go compatibility oracle

**Repository:** noana-org/ritma-app @ `5b1698f` (main), branch `feat/go-wellness-engine`
**Date:** 2026-08-19
**No PII:** all cases use synthetic users (uuid `u1`, `u2`, ...) and fabricated
physiological values.

## Oracle provenance (IMPORTANT — read first)

ritma-app ships **no tests** (only `test/widget_test.dart`). To build a real
compatibility oracle, the pure algorithm classes were executed directly with the
Flutter/Dart SDK on this machine:

- Harness: `test/golden_oracle_test.dart` (added on this branch).
- Execution: `flutter test test/golden_oracle_test.dart` → **5/5 passed** →
  wrote `docs/golden/oracle.json`.
- The harness imports the ACTUAL production classes
  (`SleepScoreAlgorithm`, `StressScoreAlgorithm`, `ReadinessScoreAlgorithm`,
  `ActivityScoreAlgorithm`, `ActivityKcalGoal`, `WellnessBaselines`,
  `DemographicPrior`) — it does NOT re-implement them.

Coverage split:

| Scope | Source of expected values |
|---|---|
| F-01 sleep score (pure `compute`) | **MACHINE-EXECUTED** (real Dart code) |
| F-02 stress (algorithm layer) | **MACHINE-EXECUTED** (real Dart code) |
| F-03 readiness (algorithm layer: blend/caps/RHR/SpO2/fatigue) | **MACHINE-EXECUTED** |
| F-04 activity (goal conversions, day target, peak aggregation) | **MACHINE-EXECUTED** |
| F-05/06 baseline helpers (confidence, shrinkage) | **MACHINE-EXECUTED** |
| F-10 demographic priors | **MACHINE-EXECUTED** |
| F-12 night pipeline (gap-fill, 1h expunge, cap) | **HAND-DERIVED** (needs Isar; step-by-step below, verify in differential harness Phase 20) |
| F-03 full service pipeline (RHR/SpO2/fatigue via DB) | **HAND-DERIVED** (needs Isar) |
| F-05/06 rolling nightly baselines | **HAND-DERIVED** (needs Isar) |
| F-08/09 auto-update guardrails | **HAND-DERIVED** (needs prefs/Isar) |

The Go implementation MUST reproduce every MACHINE-EXECUTED value exactly
(tolerance: exact integer for scores; 1e-9 relative for doubles). The
HAND-DERIVED cases are the target of the Phase 20 differential harness.

## A. Machine-executed golden cases (docs/golden/oracle.json)

### A.1 Sleep score (F-01) — inputs: bedtime 22:00 (1320), target 8h (480)

| case | night | score | msg1 | msg2 | msg3 | derivation |
|---|---|---|---|---|---|---|
| sleep_ideal | on time, 480min, REM22/DEEP20/LIGHT58 | 100 | 0 | 0 | 3 | no discounts; msg3=3 (light>50) |
| sleep_late_60 | start 23:00 (+60) | 98 | 1 | 0 | 3 | (60−30)*0.0899=2.697→int 2 |
| sleep_late_150 | start 00:30 (+150) | 87 | 2 | 0 | 3 | 60*0.0899+60*0.1333=13.392→13 |
| sleep_short_330 | 330min (−150) | 70 | 0 | 4 | 3 | 60*0.25+60*0.2666=30.996→30 |
| sleep_over_570 | 570min (+90) | 94 | 0 | 1 | 3 | 60*0.25=15 ×coef0 0.4 (≤90!) =6 |
| sleep_poor_quality | REM12 DEEP8 | 91 | 0 | 0 | 0 | quality 4+5=9 |
| sleep_battery_depleted | battery<3% | 0 | — | — | — | bateriaZerada=true |
| sleep_empty | no segments | 0 | — | — | — | isEmpty |

Key traps for Go:
- `pctLight` computed as `light/sleepingTime*100` yields
  **57.99999999999999** (IEEE754) — the breakdown msg3 comparison
  (`pctLight > 50`) still passes, but a Go implementation using exact
  arithmetic would produce `58.0`. Match IEEE754 double semantics or compare
  with tolerance.
- The `+90` duration-over case uses `durationOverCoefLight` (0.4), NOT
  `durationOverCoefHeavy` — the `<= somewhat` boundary is inclusive.
- Discount total is truncated with `.toInt()` (not rounded) before
  `100 − total`.

### A.2 Stress (F-02) — algorithm layer

| case | input | baseline | lnSd | trend | score |
|---|---|---|---|---|---|
| stress_healthy_21d | 21 daily avgs 40→70 rising | 55.0 | 0.20 (clamped) | 67.0 | 21 |
| stress_stressed_21d | 21 daily avgs 28→20 falling | 24.0 | 0.20 (clamped) | 20.8 | 36 |
| stress_insufficient_days | 4 days | — | — | — | 0, downCount=1 |
| stress_z_edge_2x | baseline 40, observed 85 | — | — | — | z=−0.4 → 24.5200… |
| stress_sanitize_clamp | baseline 40, observed 100 | — | — | — | sanitized 62.0 (=40*1.55) |
| stress_lnsd_single_day | [42.0] | — | — | — | defaultLnSd 0.22 |

Go traps: ln domain uses `ln(clamp(ms,1,∞))`; lnSd is sample stddev (n−1)
clamped [0.20, 0.40]; the `observed >= 2*baseline → z=−0.4` short-circuit
fires BEFORE the sanitize clamp; sigmoid = 1/(1+exp(−0.72(z−2))).

### A.3 Readiness algorithm (F-03) — component functions

| case | input | output |
|---|---|---|
| sleep_aggregate | today 85, hist 70 | 81 (=round(85*.7+70*.3)) |
| fatigue_lerp | avgs [0,8,20,25,30,40,50,65,80] | [0,3,8,12,15,25,38,65,80] |
| caps | blend 90, todaySleep [10,35,45,55,70] | [35,45,58,72,90] |
| rhr | rhr [58,65,70,75,80] vs baseline 65 | [100,100,36,0,0] |
| spo2 absolute | [97,96,95,93,91,89] | [100,100,60,15,5,0] |
| spo2 personal (baseline 96) | [97,96,95.5,94,92,89] | [100,100,70,60,27,0] |
| blend all | sleep80 rec70 rhr90 spo2100 fat85 | 82 |
| blend no-optional | sleep80 rec70 (weights renorm) | 76 |

### A.4 Activity (F-04)

| case | input | output |
|---|---|---|
| goalKcal | steps [7000,5000,3000,20000,0] | [280,200,150,800,150] |
| dayTarget | readiness [0,30,55,80,100] | [100,41,55,69,80] |
| todayTargetKcal | goal 280, pct [30,55,90] | [80,150,250] |
| scoreFromKcal | kcal [0,140,280,420,999] vs goal 280 | [0,50,100,100,100] |
| aggregateSteps | 3 bracelet records peak | steps 800, kcal 32.0, dist 640.0 |
| preferWearable | RING+BRACELET mixed | BRACELET chosen, peak 800 |

### A.5 Baselines + demographics

| case | input | output |
|---|---|---|
| confidence | n [0,1,7,13,14,29,30,45] | none/early/provisional/provisional/good/good/optimal/optimal |
| shrinkage | obs 72, prior 65, n [0,5,15,30,60] | 65 / 66.1667 / 68.5 / 72 / 72 |
| steps prior | age65/age25/bmi30/female/male/all | 6000 / 7500 / 6500 / 7000 / 7500 / 7500 |
| sleep target prior | age 20 / 70 / 40 | 510 / 450 / 480 |

## B. Hand-derived golden cases (pipeline — needs Isar; verify via differential harness)

### B.1 Night pipeline (F-12) — segment processing

All timestamps local, night D = 2026-08-10 → window [2026-08-09 18:00, 2026-08-10 12:00].

CASE N1 — normal night with a gap (device omits wake):
segments: [22:00→23:00 REM], [23:00→00:30 Light], [00:30→01:00 missing],
[01:00→06:30 Light], [06:30→07:00 REM]
- bounds: minStart 22:00, maxEnd 07:00
- gap-fill: 00:30→01:00 = Wake
- no 1h+ awake run (max run = 30min) → no expunge
- totals: REM 1h+0.5h=1.5h, Light 1.5h+5.5h=7h, Wake 0.5h, sleeping=8.5h,
  duration=9h (within 16h cap)
- EXPECTED: start 22:00, end 07:00, sleepingTime 30,600,000 ms, pctRem 17.65,
  pctDeep 0, pctLight 82.35, pctAwake 5.56

CASE N2 — sleep split by long awake gap (≥1h):
segments: [22:00→01:00 Light], [01:00→02:30 Wake], [02:30→06:00 Light]
- gap-fill: nothing to fill (segments contiguous)
- first ≥1h awake run: 01:00→02:30 (90min)
- sleep before = 3h, sleep after = 3.5h → after ≥ before → KEEP AFTER
- EXPECTED: windowStart 02:30, windowEnd 06:00, sleepingTime 3.5h (12,600,000ms),
  light 100%, wake 0

CASE N3 — clamped-to-nightEnd segment:
segments: [2026-08-09 22:00 → 2026-08-10 12:00 Deep] (ends exactly at nightEnd)
- raw segment end == nightEnd → clamped flag
- bounds: maxEnd = last segment's START = 22:00?? → the code sets
  `maxEnd = segments.last.start` ONLY when lastEndWasClamped → maxEnd = 22:00
- → window [22:00, 22:00] → empty → **EXPECTED: empty summary** (night discarded).
  This is a real edge: a single segment clamped at nightEnd yields empty.

CASE N4 — duration cap:
segments covering 20h of sleep stages (e.g., 14:00→10:00 next day)
- totalDuration = 20h → capped to 16h (57600000 ms)
- NOTE: per-stage sums are NOT capped (only totalDuration); stage %s still use
  uncapped sums / capped duration semantics per code order
- EXPECTED: duration 57,600,000 ms

CASE N5 — battery depleted:
last BatteryRecord with timestamp < nightEnd+1 has value 2.5 → batteryDepleted=true

### B.2 Full readiness pipeline (F-03 service) — user `u1`, date 2026-08-10

Setup: stress score 40 (from B.3 data), sleep scores D=90, D−1=85, D−2=70,
D−3=0 (no data), D−4=80; nightly RHR D=62, baseline 30-night median 64.5
(blend w=20/30: 64.5*0.6667+65*0.3333=64.67); SpO2 tonight 95.2, baseline
mean 96.1 (blend 20/30: 96.1*0.6667+96*0.3333=96.07).

- sleepHistoricalAvg = ceil((85+70+80)/3) = ceil(78.33) = **79**
- sleepComponent = round(90*0.7 + 79*0.3) = round(86.7) = **87**
- recoveryComponent = 100−40 = **60**
- rhrComponent = scoreRhrVsBaseline(62, 64.67): ratio 0.9587 ≤ 1 → **100**
- spo2Component = scoreSpo2(95.2, baseline 96.07): delta −0.87 → 80+(−0.87*20)
  = round(62.6) = **63**
- fatigueAvgSleep = round((85+70+80)/3) = round(78.33) = **78** → ≥65 → **78**
- blend = (87*.35 + 60*.25 + 100*.15 + 63*.10 + 78*.15)/1.0
        = 30.45 + 15 + 15 + 6.3 + 11.7 = 78.45 → round → **78**
- caps: todaySleep 90 > 60 → no cap → **readiness 78**

### B.3 Stress full service (F-02) — same user/date

21 daily averages (ms): [38,39,40,39,38,40,41,40,39,38,37,38,39,40,39,38,37,36,37,36,35]
- baselineMs = mean = 38.43
- lnSd over ln values (clamped to [0.20,0.40])
- trend = 7-day linearly weighted mean of last 7 values [38,37,36,37,36,35]
  weights 1..6 → (38*1+37*2+36*3+37*4+36*5+35*6)/21 = (38+74+108+148+180+210)/21
  = 758/21 = 36.10
- observed 36.10 < baseline → z > 0 → stress ~40s range (exact value: compute
  in differential harness; not asserted here to avoid hand-rounding drift)
- EXPECTED: stressScore int in [35, 45] band for the oracle, exact value
  asserted by the Go differential test once implemented.

### B.4 Auto-update guardrails (F-08/F-09)

- steps: confidence good (14+ sample days), no manual override, cooldown
  elapsed → newGoal = round5(shrinkage-blended median) clamped [3000, 15000],
  delta vs current capped at ±35% of current.
- sleep: same guardrails; bedtime delta cap ±30 min; target ±30 min; target
  clamp [300, 600]; quarter-hour rounding.
- These mutate state (prefs/Parameter) — design decision: the Go engine treats
  auto-update as a SEPARATE maintenance operation (see architecture doc), not
  part of "calculate day".

## C. Coverage matrix vs required scenarios

| Scenario | Covered by |
|---|---|
| normal day | sleep_ideal, stress_healthy, readiness blend all, activity 50% |
| excellent day | sleep_ideal (100), spo2 100, rhr 100 |
| poor day | sleep_short_330 (70), stress_stressed (36), spo2 15 |
| missing data | sleep_empty, stress_insufficient_days, blend no-optional |
| partial day | fatigue lerp missing days (B.2: D−3=0 skipped) |
| zero values | scoreFromKcal 0, activity 0 steps, stress z=0 path |
| boundary values | caps thresholds (30/40/50/60), rhrZeroRatio 1.12, spo2 deltas −1/−3/−6, duration boundary 90, nightEnd clamp (N3), 16h cap (N4) |
| baseline unavailable | shrinkage n=0 → prior, confidence none, rhrComponent null |
| new user | demographic priors (steps 7000 ±, sleep 480 ±) |
| timezone/day boundary | N1-N3 night windows crossing midnight; bedtime wrap ±720 min (sleep score) |
| battery depleted | sleep_battery_depleted, N5 |
| float sensitivity | sleep_ideal pctLight 57.99999999999999 |
| goal increase/decrease/unchanged | goal_s1/s2/s3 |
| cap boundary (2450 vs 2455 delta) | goal_s4 (capped 9450) / goal_s4b (uncapped) |
| insufficient history (7–13 days) | goal_s5 (10d → UPDATED, provisional) |
| missing days (zeros) | goal_s6 (14 good + 16 zero days) |
| extreme high/low | goal_s7 (→9450) / goal_s8 (→4550) |
| new user (seed prior) | goal_s9 |
| manual override | goal_s10 / goal_t4 |
| repeated update (cooldown) | goal_s11 (1st applied, 2nd blocked) |
| sleep bedtime/target shift | goal_t1/t2, unchanged t3, insufficient t5 |

## A3. Goal oracle (F-08/F-09) — docs/golden/oracle-goals.json

Machine-executed against the REAL production implementation
(PersonalizedLifestyleBaseline.maybeAutoUpdateAll) with a real in-memory
Isar DB (native libisar.so initialized manually — flutter test cannot
auto-load it) + mocked SharedPreferences. 17 cases (12 steps + 5 sleep) over
synthetic data; runner: `flutter test test/goal_oracle_test.dart -j 1`.

Each case records stepsBaseline {value/prior/observed/sampleCount/confidence},
sleepBaselines {bedTimeMinutes/sleepTargetMinutes/priors/sampleCount/
confidence/bedtimeStdDevMinutes}, update {stepsUpdated/newStepsGoal/
sleepUpdated/newBedTimeMinutes/newSleepTargetMinutes} and the persisted
goal (Parameter.limitMax read back).

Go parity: `wellness-engine/internal/goals` golden tests reproduce every
case. IMPORTANT oracle finding: auto-update fires from PROVISIONAL
confidence (7+ samples; minConfidenceForAutoUpdate=2), NOT good — the
calibration comment is stale (audit F-08).

## D. Go reproduction requirements

1. `docs/golden/oracle.json` is the machine-generated reference — commit it
   with the audit (it is deterministic: same Dart code + same inputs → same
   JSON).
2. Go golden tests must reproduce every A-section value. Tolerance policy:
   - integer scores: EXACT match.
   - doubles: relative 1e-9 (IEEE754 ops in the same order as Dart) — the
     pctLight 57.99999999999999 case must reproduce the same float artifact
     OR the test asserts with tolerance and documents the deviation.
3. B-section values are asserted only by the Phase 20 differential harness
   (real Isar-backed execution vs Go engine).
4. **Stage-mapping verification case (new)**: before trusting any
   deep/light-derived golden value, verify the raw→canonical mapping against
   a real device (executing mapper: raw 1→Light, 2→Deep; ingestion comment
   claims 1=deep, 2=light — see audit supplementary findings #1). The golden
   dataset currently encodes the EXECUTING mapper (stage values are canonical
   −4..0 at input to F-01/F-12, so the mapping only matters at ingestion
   time).
