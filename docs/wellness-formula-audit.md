# Wellness Formula Audit — ritma-app

**Repository:** https://github.com/noana-org/ritma-app
**Branch audited:** main @ `5b1698f` ("V 1.1.6 - início dos testes reais")
**Audit date:** 2026-08-19
**Scope:** All health/wellness formulas, calculation rules, constants, thresholds,
windows, baselines and missing-data behavior implemented in the Flutter app.
**Method:** read-only source inspection. Every formula below cites file:line and
quotes the governing code. Nothing was inferred from filenames alone.

> The ritma-app is the FIRST and ONLY authoritative implementation of the
> wellness formulas in the Noana/Ritma family. The upstream
> `noana-wellness-app` (Phase 5) only has the DailyScore *upload contract* with
> nullable fields and NO formula code (`test/score_service_test.dart`, fixtures
> 91/84). The clinical `noana-front-app-code` does not contain these formulas.
> `HANDOFF.md` references `noana/docs/FORMULA_*.md` which do NOT exist in any
> repo available locally.

---

## Score architecture (facade)

`lib/core/scores/wellness_scores.dart` — `WellnessScores.calculateRings(date, personUuid)`
is the single entry point for the three home rings (Sono / Prontidão / Atividade).

Orchestration (wellness_scores.dart:42-94):

1. `PersonaizedLifestyleBaseline.maybeAutoUpdateAll(personUuid, date)` (goal learning, side effects).
2. `sleep = SleepScoreService.scoreOnly(date, personUuid)` (ceil of computed int).
3. `stressMap = StressScoreService.calculate(date, personUuid)` → `stressScore` (round),
   `downCount`, `instantHrvMs`, `baselineMs`.
4. `readiness = ReadinessScoreService.calculateBreakdown(date, personUuid, stressScore,
   downCount, instantHrvMs, hrvBaselineMs, getSleepScore: _sleep.scoreOnly).totalScore`.
5. `activity = ActivityScoreService.calculate(date, personUuid, readiness)`
   → `activityScore` (ceil), `dayTargetPercent`, `zoneStartPercent` (dayTarget−10),
   `zoneEndPercent` (dayTarget+10).

Missing-data gate: `personUuid.isEmpty` → all zeros. Readiness additionally bails
(returns 0) when `stressScore <= 0` or `todaySleepScore <= 0` (readiness_score.dart:192-196).

---

## F-01 — Sleep Score (discount model)

FORMULA ID: F-01
NAME: Sleep Score
SOURCE FILE: lib/core/scores/sleep_score.dart
SOURCE FUNCTION: `SleepScoreAlgorithm.compute` (lines 16-149)
PURPOSE: 0–100 sleep score from night summary + target bedtime/duration. Starts at
100 and subtracts three discounts (bedtime, duration, stage quality).
OUTPUT: `sleepScore` int 0–100 (already int; `scoreOnly` applies `.ceil()`), plus
analysis codes msg1/msg2/msg3 and `bateriaZerada` flag.

INPUTS:
- `summary` (SleepStageSummary) — night window [18h D−1, 12h D] (see F-13)
  - `startTimeStamp` ms epoch (sleep onset)
  - `sleepingTime` ms (rem+nap+light+deep, no wake)
  - `pctRem`, `pctDeep`, `pctLight` (% of sleepingTime)
  - `batteryDepleted` bool
- `bedTimeMinutes` int — target bedtime as minute-of-day (prefs `wellness_bed_time_minutes`, default 1320 = 22:00, or DemographicPrior)
- `sleepTargetMinutes` int — target duration (prefs `wellness_sleep_target_minutes`, default 480 = 8h, or DemographicPrior)

FORMULA:

```
actualBedtime = minuteOfDay(summary.startTimeStamp)          // local device time
diff = actualBedtime − bedTimeMinutes                        // wrapped to [−720, 720]

// early coefficient (see NOTE below — dead path)
coef0 = 1.0
if diff < −onTime and diff >= −somewhat: coef0 = earlyCoefLight       // 0.3
if diff < −somewhat:                          coef0 = earlyCoefHeavy  // 0.65

bedTimeDiscount = 0
if onTime < diff <= somewhat: bedTimeDiscount = (diff − onTime) * bedLateCoef1
if diff > somewhat:           bedTimeDiscount = (somewhat − onTime)*bedLateCoef1
                                             + (diff − somewhat)*bedLateCoef2
bedTimeDiscount = min(bedTimeDiscount * coef0, maxBedTimeDiscount)

sleepingMin = round(sleepingTime / 60000)
diff2 = sleepingMin − sleepTargetMinutes
coef0 = 1.0
if onTime < diff2 <= somewhat: coef0 = durationOverCoefLight   // 0.4
if diff2 > somewhat:           coef0 = durationOverCoefHeavy   // 0.75

abs2 = |diff2|
targetSleepDiscount = 0
if onTime < abs2 <= somewhat:      = (abs2 − onTime) * durationCoef1
if somewhat < abs2 <= 180:         = (somewhat−onTime)*durationCoef1
                                 + (abs2 − somewhat)*durationCoef2
if abs2 > 180:                     = (somewhat−onTime)*durationCoef1
                                 + (180 − somewhat)*durationCoef2
                                 + (abs2 − 180)*durationCoef3
targetSleepDiscount = min(targetSleepDiscount * coef0, maxDurationDiscount)

qualityDiscount = stageQualityDiscount(pctRem) + stageQualityDiscount(pctDeep)
  stageQualityDiscount(pct): pct<10 → 5; pct<15 → 4; pct<20 → 3; pct>27.5 → 2; else 0

sleepScore = clamp(100 − (qualityDiscount + bedTimeDiscount + targetSleepDiscount), 0, 100)
   (totalDiscount = sum .toInt(); per-discount values stay double until sum)
```

CONSTANTS/WEIGHTS (SleepScoreCalibration, score_calibration.dart:24-70):
onTimeThresholdMin=30, somewhatThresholdMin=90, maxBedTimeDiscount=15,
maxDurationDiscount=65, bedLateCoef1=0.0899, bedLateCoef2=0.1333,
earlyCoefLight=0.3, earlyCoefHeavy=0.65, durationOverCoefLight=0.4,
durationOverCoefHeavy=0.75, durationCoef1=0.2500, durationCoef2=0.2666,
durationCoef3=0.2777, defaultBedTimeMinutes=1320, defaultSleepTargetMinutes=480.

NOTE (dead logic): the early-sleep coefficients (`earlyCoefLight`/`earlyCoefHeavy`)
are assigned to `coef0` ONLY in branches where `bedTimeDiscount` is 0 (early
branches), and `coef0` is multiplied only into `bedTimeDiscount` (which is 0
there). Result: early bedtime NEVER changes the score. The late-duration
coefficients DO apply (sleeping longer than target discounts less).
Cross-checked against the other available repos: no other implementation exists
to compare. Confidence in the dead-path finding: HIGH (control flow is local and
unambiguous); the *intent* (early bedtime should help? hurt?) is UNKNOWN.

MISSING DATA BEHAVIOR:
- `summary.isEmpty` (duration <= 0) → sleepScore 0, bateriaZerada false.
- `summary.batteryDepleted` (last battery sample before night end < 3.0) → sleepScore 0, bateriaZerada true (sleep deemed incomplete).
- personUuid empty → `{'sleepScore': 0}`.
- Missing HRV does not affect sleep score.

EDGE CASES:
- diff wrapping: ±720 min rule (`>720 → −1440`, `<−720 → +1440`) — a 13h wrap.
- duration overshoot beyond 180 min uses third coefficient (0.2777).
- Total discount can exceed 100 → clamp to 0.

ROUNDING: sleepingMin rounds ms→min (half away from zero via `.round()`);
final score int-truncates the discount sum (`(…).toInt()`), so e.g. total
discount 34.9 → 34 → score 66.

OUTPUT RANGE: 0–100 (int). Analysis codes: msg1 0–4, msg2 0–4, msg3 0–5
(see code, sleep_score.dart:95-134).

DEPENDENCIES: SleepStageSummary.forNight (F-13); prefs bed/target (F-08/F-09).
USED BY: WellnessScores.calculateRings; ReadinessScoreService (as lookup for
today + history).
TEST COVERAGE: NONE in ritma-app (only test/widget_test.dart exists).
CONFIDENCE: HIGH
NOTES: The score ring displays ceil(score) — no-op since int. Historical sleep
scores for readiness use the same service.

---

## F-02 — Stress Score (HRV log-domain)

FORMULA ID: F-02
NAME: Stress Score (trend) + Instant HRV
SOURCE FILE: lib/core/scores/stress_score.dart
SOURCE FUNCTION: `StressScoreAlgorithm.*` + `StressScoreService.calculate` (lines 100-191)
PURPOSE: 0–100 stress score from HRV daily averages; LOWER = better stress
(= higher HRV = lower stress). 0 = no data.
OUTPUT: `stressScore` (int, round), `downCount` (int, days still missing to
reach minDaysRequired), `baselineMs`, `baselineLnSd`, `instantHrvMs`, `dailyAverages`.

INPUTS:
- `hrvRecords`: HrvRecord{personUuid, timestamp ms epoch, value ms, deviceSource}
  — value is the JStyle-SDK-provided HRV in **ms** (parameter key
  `vitals_cardiac_hrv_ms_value`; semantics = device-computed HRV, assumed RMSSD —
  see AMBIGUITIES). Filtered: `value != null && value > 0 && timestamp != null`.
- Window: `[endDate − 21 days, endDate]` where endDate = `DateTime(y,m,d,23:59:59)`
  local — **21-day window includes the anchor day** (baselineWindowDays=21).

FORMULA:

```
dailyAvg[d] = mean of hrv values for local calendar day d     // dayKey = y*400+m*31+d
if count(dailyAverages) < minDaysRequired(5) → stressScore 0, downCount = 5 − count

baselineMs = mean(dailyAvg over all days in window)           // simple mean, up to 21 days
baselineLnSd = sampleStdDev( ln(dailyAvg) )                   // n−1 denominator
               clamped [minLnSd=0.20, maxLnSd=0.40]; if n<2 → defaultLnSd=0.22

trendMs = linearWeightedMean(last min(7, n) dailyAvg)         // weights 1..k (oldest→newest)
observed = trendMs > 0 ? trendMs : dailyAvg.last              // fallback

safe = clamp(observed, baselineMs*0.45, baselineMs*1.55)      // sanitize (only if both > 0)
if observed >= baselineMs*2.0: z = −0.4                        // special case BEFORE clamp
else: z = (ln(baselineMs) − ln(safe)) / clamp(baselineLnSd, 0.20, 0.40)
z = clamp(z, −1.0, 3.0)
logistic = 1 / (1 + exp(−0.72 * (z − 2.0)))
stressScore = round(clamp(12.0 + 83.0*logistic, 12.0, 95.0)).clamp(0, 100)

// Instant HRV (geometric mean over most recent non-empty window):
for windowMin in [15, 60, 180]:
  samples = hrv with timestamp >= now − windowMin*60k
  if samples non-empty: instantMs = exp(mean(ln(samples))); break
if none → instantMs = 0
```

CONSTANTS/WEIGHTS (StressScoreCalibration, score_calibration.dart:72-104):
defaultLnSd=0.22, minLnSd=0.20, maxLnSd=0.40, zClampMin=−1.0, zClampMax=3.0,
minScoreWithData=12.0, baselineWindowDays=21, minDaysRequired=5,
rollingTrendDays=7, instantWindowMinutes=[15,60,180], sigmoidMidpoint=2.0,
sigmoidSteepness=0.72, sigmoidSpan=83.0.
`instantFallbackHours=24` is DECLARED BUT NEVER USED (dead config).

MISSING DATA BEHAVIOR:
- No valid records → stressScore 0, downCount 5, baselineMs 0.
- <5 days with data → stressScore 0, downCount = 5 − n (partial credit).
- observed <= 0 or baseline <= 0 → z=0 → score ~= 12+83*sigmoid(−1.44) ≈ 15.3 → 15.
  (Can only happen via zero/negative inputs that are filtered upstream; guarded anyway.)

EDGE CASES: observed >= 2×baseline short-circuits z to −0.4 (protects against
implausibly high HRV); ln uses clamp(ms, 1.0, ∞) (0/negative → ln(1)=0).

ROUNDING: dailyAvg stays double; final `.round()`.

OUTPUT RANGE: 0 (no data) or 12–95 (with data), int after round.
DEPENDENCIES: HrvRecord collection (Isar). None on other scores.
USED BY: WellnessScores.calculateRings → readiness (recovery component + gate).
TEST COVERAGE: NONE.
CONFIDENCE: HIGH
NOTES: Score is a monotone decreasing function of HRV (higher HRV → lower
stress). The sigmoid maps z≈2.0 → 50% (stress ~54).

---

## F-03 — Readiness Score (weighted blend + caps)

FORMULA ID: F-03
NAME: Readiness Score
SOURCE FILE: lib/core/scores/readiness_score.dart
SOURCE FUNCTION: `ReadinessScoreAlgorithm.*` (57-135) + `ReadinessScoreService.calculateBreakdown` (163-296)
PURPOSE: 0–100 readiness from sleep (today + history), recovery (inverse stress),
RHR deviation, night SpO2, and fatigue (recent sleep average).
OUTPUT: `totalScore` int 0–100, plus full breakdown (components, RHR/SpO2
tonight + baselines, fatigue avg).

INPUTS:
- `stressScore` int (from F-02; REQUIRED, gate: <=0 → result 0)
- `getSleepScore(date, personUuid)` — SleepScoreService.scoreOnly (F-01)
- `downCount`, `instantHrvMs`, `hrvBaselineMs` (passed through; not used in math)
- RHR tonight (F-05), RHR baseline (F-05), night SpO2 (F-06), SpO2 baseline (F-06)
  — all optional (null if no data)

FORMULA:

```
sleepHistoricalAvg = ceil( mean( sleepScore(D−1..D−4) where score>0 ) )
                     if no valid day → sleepHistoricalAvg = todaySleepScore
sleepComponent = round(todaySleepScore*0.70 + sleepHistoricalAvg*0.30).clamp(0,100)
recoveryComponent = clamp(100 − stressScore, 0, 100)

rhrComponent = scoreRhrVsBaseline(lastNightRhr, rhrBaseline):
   if baseline <= 0 → 0
   ratio = lastNightRhr / rhrBaseline
   ratio <= 1.0 → 100
   ratio >= rhrZeroRatio(1.12) → 0
   else → round(((1.12 − ratio)/0.12) * 100).clamp(0,100)

spo2Component = scoreSpo2(avgPct, personalBaseline):
   if baseline > 0 (personal):
     delta = avgPct − baseline
     delta >= 0  → 100
     delta >= −1 → round(80 + delta*20).clamp(0,100)
     delta >= −3 → round(40 + (delta+3)*20).clamp(0,100)
     delta >= −6 → round((delta+6)/3 * 40).clamp(0,100)
     else        → 0
   else (absolute):
     avgPct >= 96 → 100
     avgPct >= 94 → round(20 + (avgPct−94)/2*80).clamp(0,100)
     avgPct >= 90 → round((avgPct−90)/4*20).clamp(0,100)
     else         → 0

fatigueAvgSleep = round( mean( sleepScore(D−1..D−3) where score>0 ) )   // if any
fatigueComponent = scoreFatigueFromAverage(fatigueAvgSleep):
   avg >= 65 → avg (identity)
   else piecewise linear lerp on (x0,y0)-(x1,y1) knots, rounded:
     [0,20]→[0,8], [20,30]→[8,15], [30,40]→[15,25], [40,50]→[25,38],
     [50,65]→[38,65]
     lerp(x) = round(y0 + (y1−y0)*(x−x0)/(x1−x0))

blended = weightedBlend({sleep: w=0.35, recovery: w=0.25,
                         rhr: w=0.15 (if present), spo2: w=0.10 (if present),
                         fatigue: w=0.15 (if present)})
        = round( Σ(score*weight) / Σ(weight) ).clamp(0,100)

totalScore = applyReadinessCaps(blended, todaySleepScore):
   todaySleepScore <= 30 → min(blended, 35)
   todaySleepScore <= 40 → min(blended, 45)
   todaySleepScore <= 50 → min(blended, 58)
   todaySleepScore <= 60 → min(blended, 72)
   else → blended
```

CONSTANTS/WEIGHTS (ReadinessScoreCalibration, score_calibration.dart:106-142):
weightSleep=0.35, weightRecovery=0.25, weightRhr=0.15, weightSpo2=0.10,
weightFatigue=0.15, sleepTodayWeight=0.70, sleepHistoryWeight=0.30,
fatigueIdentityThreshold=65, rhrZeroRatio=1.12, fatigueLookbackDays=3,
sleepHistoryDays=4, capSleep30=35, capSleep40=45, capSleep50=58, capSleep60=72.
`rhrBaselineWindowDays=21` DECLARED BUT NEVER USED (baseline uses 30, see F-05).

MISSING DATA BEHAVIOR:
- stressScore<=0 OR personUuid empty → full-empty result (totalScore 0).
- todaySleepScore<=0 → full-empty result (0).
- No RHR tonight or no RHR baseline → rhrComponent null (excluded from blend).
- No SpO2 tonight → spo2Component null (baseline can exist; component requires tonight).
- No fatigue days → fatigueComponent null.
- Missing components renormalize the weighted average (Σweights < 1).
- sleepHistoricalAvg falls back to today's score when no history.

EDGE CASES: rhr baseline<=0 → rhrComponent 0 (but null if either input null);
caps only ever LOWER the blend.

ROUNDING: weightedBlend `.round()`; sleepAggregate `.round()`; historical avg
`.ceil()`; fatigue avg `.round()`; RHR/SpO2 component `.round()`.

OUTPUT RANGE: 0–100 int. `hasData => totalScore > 0`.
DEPENDENCIES: F-01 (sleep scores today+history), F-02 (stress), F-05 (RHR
baselines), F-06 (SpO2 baselines), F-13 (night window).
USED BY: WellnessScores.calculateRings.
TEST COVERAGE: NONE.
CONFIDENCE: HIGH
NOTES: RHR/SpO2/fatigue components are OPTIONAL — a user with only sleep+stress
gets a 2-component blend (weights renormalized to 0.35/0.25 → 58%/42%).

---

## F-04 — Activity Score (kcal-based)

FORMULA ID: F-04
NAME: Activity Score + adaptive day target
SOURCE FILE: lib/core/scores/activity_score.dart
SOURCE FUNCTION: `ActivityScoreAlgorithm.*` + `ActivityScoreService.calculate` (112-191)
PURPOSE: 0–100 activity from kcal against an adaptive goal; also computes
dayTargetPercent and the strain-zone band (dayTarget ±10).
OUTPUT: `activityScore` (int, round then ceil — no-op), `totalSteps`, `totalKcal`,
`wearableDayKcal`, `sessionKcal`, `goalSteps`, `goalKcal`, `dayTargetPercent`,
`todayTargetKcal`, `zoneStartPercent`, `zoneEndPercent`.

INPUTS:
- `stepsRecords` for local day [00:00:00, 23:59:59.999]: StepsRecord{value,
  calories, distance, deviceSource, timestamp} — **cumulative counters** (see
  aggregation below).
- `activitySessionRecords` status='completed' with startTime in [dayStart, nextDay):
  `calories` per session.
- `readinessScore` int (from F-03).
- goalSteps: Parameter limitMax for key `vitals_activity_pedometer_steps_data_value`
  if > 0, else DemographicPrior.priorDailyStepsFromProfile() (F-10).

FORMULA:

```
aggregateSteps(records)  // preferWearable: BRACELET → RING → rest (per record set)
  sort by timestamp asc
  steps   = max over records of value        // PEAK (counter), int truncation
  calories= max over records of calories     // PEAK
  distance= max over records of distance     // PEAK

goalKcal = roundToNearest10( round(goalSteps * 0.04) ), clamped [150, 800]
           (goalSteps<=0 → minGoalKcal=150)

totalKcal = clamp( round(wearableDayKcal) + sessionKcal, 0, 100000 )

dayTargetPercent(readiness):
  readiness <= 0 → 100
  else round(readiness*0.55 + 55*0.45), clamped [30, 90]

todayTargetKcal = roundToNearest10( round(goalKcal * dayTargetPercent / 100) )
                  clamped [0, maxGoalKcal]

activityScore = round(100 * totalKcal / goalKcal).clamp(0,100)   // goalKcal<=0 → 100

zoneStartPercent = clamp(dayTargetPercent − 10, 0, 100)
zoneEndPercent   = clamp(dayTargetPercent + 10, 0, 100)
```

CONSTANTS/WEIGHTS (ActivityScoreCalibration, score_calibration.dart:144-166):
defaultGoalSteps=7000, kcalPerStep=0.04, minGoalKcal=150, maxGoalKcal=800,
dayTargetReadinessWeight=0.55, dayTargetNeutral=55, dayTargetMin=30, dayTargetMax=90.

MISSING DATA BEHAVIOR:
- personUuid empty → zeros + defaultGoalSteps/emptyGoal.
- No steps records → steps 0, kcal 0 → score 0 (goalKcal still computed).
- No sessions → sessionKcal 0 (try/catch → 0).
- goalSteps param missing → demographic prior.
- Readiness 0 → dayTarget 100 (no adaptation).

EDGE CASES: kcal goal clamps to [150,800] even if steps goal huge; score 100 when
goalKcal<=0 (defensive); 100000 kcal cap.

ROUNDING: `.round()` at each conversion; steps truncate `toInt()` after peak;
kcal goal rounds to nearest 10.

OUTPUT RANGE: 0–100 int.
DEPENDENCIES: F-03 (readiness), F-08/F-10 (goal steps), Isar steps+activity
sessions.
USED BY: WellnessScores.calculateRings.
TEST COVERAGE: NONE.
CONFIDENCE: HIGH
NOTES: Steps are CUMULATIVE daily counters from the JStyle SDK — "peak of the
day" is the aggregation that recovers the total. This is a device-specific
semantic; the Go engine must document it in the input contract.

---

## F-05 — Resting HR (nightly P10 + rolling median baseline)

FORMULA ID: F-05
NAME: Nightly Resting HR + Rolling RHR Baseline
SOURCE FILE: lib/core/scores/wellness_baselines.dart
SOURCE FUNCTION: `nightlyRestingHr` (86-111), `rollingRestingHr` (113-151)
PURPOSE: P10 of HR samples inside the sleep window; baseline = shrinkage-blended
median of the last 30 nights' P10 values.
OUTPUT: nightly P10 (double?, null if no data); NumericBaseline{value, sampleCount,
confidence}.

INPUTS:
- SleepStageSummary.forNight (F-13) — gives [startTimeStamp, endTimeStamp].
- HeartRateRecord samples in that window.
- prior = 65.0 bpm; windowDays = 30 (hardcoded `WellnessBaselines.windowDays`).

FORMULA:

```
nightlyRestingHr:
  values = hr samples in [start, end] with value > 30 and value < 220
  if empty → null
  sort; idx = floor(n*0.1) clamped [0, n−1]; return values[idx]   // P10 (nearest-rank)

rollingRestingHr(anchorDay):   // days D−1 .. D−30
  nightly = [nightlyRestingHr(D−i) for i in 1..30 if non-null]
  if empty → {value: prior(65), sampleCount: 0, confidence: none}
  observed = median(nightly)     // even n: (m[mid−1]+m[mid])/2
  w = clamp(sampleCount / 30, 0, 1)
  value = w*observed + (1−w)*prior
  confidence = confidenceFromCount(sampleCount)
```

BaselineConfidence (wellness_baselines.dart:27-33):
>=30 optimal; >=14 good; >=7 provisional; >=1 early; else none.

MISSING DATA BEHAVIOR: no sleep summary → null tonight; no nights in window →
baseline = prior 65.0 with confidence none (readiness treats sampleCount==0 as
"no baseline" → rhrComponent null).

EDGE CASES: HR filter (30,220) exclusive; even-count median averages the two
middle values.

ROUNDING: none in P10 (returns raw sample); baseline is double.

OUTPUT RANGE: bpm double; 0 → null semantics.
DEPENDENCIES: F-13.
USED BY: F-03 (rhrComponent), readiness breakdown display.
TEST COVERAGE: NONE.
CONFIDENCE: HIGH

---

## F-06 — Night SpO2 (mean) + Rolling SpO2 Baseline

FORMULA ID: F-06
NAME: Nightly Avg SpO2 + Rolling SpO2 Baseline
SOURCE FILE: lib/core/scores/wellness_baselines.dart
SOURCE FUNCTION: `nightlyAvgSpo2` (153-164), `rollingNightSpo2` (166-200),
`_avgSpo2InWindow` (202-234)
PURPOSE: mean SpO2 over the sleep window (filtered records preferred, raw
fallback); baseline = shrinkage-blended mean of last 30 nights.
OUTPUT: nightly % (double?, null if no data); NumericBaseline.

INPUTS:
- SleepStageSummary window (F-13).
- OxygenFilteredRecord (first choice) / OxygenRecord (fallback), value in [70, 100].

FORMULA:

```
avgSpo2InWindow:
  filtered = OxygenFilteredRecord in [start,end] with value in [70,100]
  if non-empty → mean(filtered)
  else raw = OxygenRecord in [start,end] with value in [70,100]
       if empty → null else mean(raw)

rollingNightSpo2(anchorDay):   // days D−1 .. D−30
  nightly = [nightlyAvgSpo2(D−i) for i in 1..30 if non-null]
  if empty → {value: prior(96.0), sampleCount: 0, confidence: none}
  observed = mean(nightly)
  w = clamp(sampleCount/30, 0, 1); value = w*observed + (1−w)*96.0
```

MISSING DATA BEHAVIOR: no sleep → null; no SpO2 in window → null; no nights →
prior 96.0 (readiness: sampleCount==0 → spo2Component null).
EDGE CASES: SpO2 out-of-range samples excluded (>=70, <=100).
ROUNDING: none (double).
OUTPUT RANGE: % double.
DEPENDENCIES: F-13.
USED BY: F-03 (spo2Component).
TEST COVERAGE: NONE.
CONFIDENCE: HIGH

---

## F-07 — Daily Steps (peak counter)

FORMULA ID: F-07
NAME: Daily Steps (peak of cumulative counter)
SOURCE FILE: lib/core/scores/wellness_baselines.dart
SOURCE FUNCTION: `dailySteps` (55-83)
PURPOSE: total daily steps for baseline windows (F-08) and streaks.
FORMULA: same peak aggregation as F-04 but BRACELET → all (no RING preference in
this function; ring records included as fallback "all").
MISSING DATA: no records → 0 (samples with value 0 are EXCLUDED upstream in
baseline loops: `if (steps > 0) samples.add(steps)`).
CONFIDENCE: HIGH

---

## F-08 — Personalized Steps Baseline (adaptive goal learning)

FORMULA ID: F-08
NAME: Personalized Steps Goal Baseline (shrinkage + auto-update)
SOURCE FILE: lib/core/scores/personalized_lifestyle_baseline.dart
SOURCE FUNCTION: `computeStepsBaseline` (161-223), `_maybeAutoUpdateStepsGoal` (329-390)
PURPOSE: personal daily-steps goal from the last 30 days, with guardrailed
auto-updates. Goal persisted in Parameter.limitMax (key
`vitals_activity_pedometer_steps_data_value`).
FORMULA:

```
prior = DemographicPrior.priorDailyStepsFromProfile()        // F-10
samples = [dailySteps(D−i) for i in 1..30 if > 0]            // F-07
if none → {value: prior, observed: null, count 0, none}
observed = medianInt(samples)                                // even: round(mean of middle 2)
w = clamp(count/30, 0, 1); value = w*observed + (1−w)*prior
confidence = confidenceFromCount(count)

Auto-update (steps) — ALL must hold:
  1. confidence.index >= 2 (= PROVISIONAL.index — updates fire from 7+
     sample days; the calibration comment "só a partir de good (≥14)" is
     STALE — the code default minConfidenceForAutoUpdate=2 wins; confirmed
     by the executed goal oracle, case goal_s5: 10 days → updated 7665)
  2. no manual override in last 30 days (prefs manualGoalOverrideAt_<uuid>)
  3. cooldown: no auto-update in last 7 days (prefs lastAutoStepsGoalUpdateAt_<uuid>)
  4. newGoal = roundToNearest5(value.round()).clamp(minDailySteps(3000),
     maxDailyStepsForAge(15000, or 12000 if age>=65))
  5. if current goal exists: maxDelta = round(currentGoal*0.35);
     |newGoal − currentGoal| > maxDelta → newGoal = currentGoal ± maxDelta
     (round to nearest 5); unchanged → no update
  6. if newGoal == demographic prior AND confidence < good → no update
persist Parameter.limitMax = newGoal; set lastAutoStepsGoalUpdateAt_<uuid> = now;
invalidate steps cache
```

CONSTANTS: stepsWindowDays=30, maxStepsChangeFraction=0.35, autoUpdateCooldownDays=7,
manualOverrideBlockDays=30, minConfidenceForAutoUpdate=2 (provisional.index),
minDailySteps=3000, maxDailySteps=15000 (12000 for ≥65).
Cache: SharedPreferences key `baselineCacheSteps_<uuid>_<yyyyMMdd>` (per anchor day).
MISSING DATA: no samples → prior; auto-update blocked until ≥7 sample days.
NOTE: auto-update timing is event-driven (runs at the START of every ring
calculation, before scores) but throttled by the 7-day cooldown and the
30-day manual-override block. Verified end-to-end by the executed goal oracle
(docs/golden/oracle-goals.json, 17 cases: test/goal_oracle_test.dart).
CONFIDENCE: HIGH (oracle-executed)

---

## F-09 — Personalized Sleep Baselines (bedtime + duration)

FORMULA ID: F-09
NAME: Personalized Bedtime / Sleep-Duration Baselines + auto-update
SOURCE FILE: lib/core/scores/personalized_lifestyle_baseline.dart
SOURCE FUNCTION: `computeSleepBaselines` (225-278), `_maybeAutoUpdateSleepConfig` (392-460)
PURPOSE: personal target bedtime and sleep duration from the last 21 nights
(with the anchor night excluded), guardrailed auto-updates persisted to prefs
`wellness_bed_time_minutes` / `wellness_sleep_target_minutes`.
FORMULA:

```
schedule = SleepStageSummary.bedtimeBaseline(uuid, anchor, 21, excludeAnchor=true)   // F-14
duration = SleepStageSummary.personalizedSleepDurationBaseline(uuid, anchor, 21, excludeAnchor=true) // F-15
sampleCount = duration.sampleCount > 0 ? duration.sampleCount : schedule.sampleCount

blendedBed = schedule.medianBedTimeMinutes != null
  ? shrinkageBlend(medianBed, priorBed(1320), schedule.sampleCount, 21) : priorBed
blendedSleep = duration.targetMinutes != null
  ? shrinkageBlend(target, priorSleep(demographic), duration.sampleCount, 21) : priorSleep

bedTimeMinutes = roundToQuarterHour(round(blendedBed))     // clamp [0, 1425]
sleepTargetMinutes = roundToQuarterHour(round(blendedSleep)).clamp(300, 600)

Auto-update (sleep) — ALL must hold:
  1. confidence.index >= 2 (= PROVISIONAL — fires from 7+ nights; same
     stale-comment situation as F-08; oracle case goal_t5: 10 nights →
     updated bed 1350)
  2. no manual sleep override in 30 days
  3. cooldown 7 days
  4. deltas capped: |newBed − currentBed| <= 30 min; |newTarget − currentTarget| <= 30 min
  5. re-round to quarter hour; target clamp [300, 600]
  6. unchanged → no update
persist prefs; set lastAutoSleepUpdateAt_<uuid> = now
```

CONSTANTS: sleepWindowDays=21, maxBedtimeChangeMinutes=30,
maxSleepTargetChangeMinutes=30, minSleepTargetMinutes=300, maxSleepTargetMinutes=600.
CONFIDENCE: HIGH (oracle-executed, 17-case goal oracle)

---

## F-10 — Demographic Priors

FORMULA ID: F-10
NAME: Demographic Priors (steps, sleep target, bedtime)
SOURCE FILE: lib/core/scores/demographic_prior.dart + wellness_demographics.dart
SOURCE FUNCTION: `DemographicPrior.*` (lines 12-74)
PURPOSE: seed goals for new users from age/BMI/gender.
FORMULA:

```
priorDailySteps:
  steps = 7000
  age >= 65 → −1000; age <= 25 → +500
  bmi >= 30 → −500
  gender F/FEMALE/MULHER → −250; M/MALE/HOMEM → +250
  clamp [3000, 15000] → round to nearest 500 (<=0 → 7000)

priorSleepTargetMinutes:
  480; age <= 25 → +30; age >= 65 → −30; clamp [300, 600]

priorBedTimeMinutes = 1320 (22:00)

maxDailyStepsForAge: age >= 65 → 12000; else 15000

BMI = weightKg / (heightCm/100)^2   (only if both > 0)
age from birthDate string (yyyy-MM-dd prefix), full years vs DateTime.now()
```

CONFIDENCE: HIGH

---

## F-11 — Streak (consecutive wearable days)

FORMULA ID: F-11
NAME: Wearable Streak
SOURCE FILE: lib/core/utils/wearable_streak.dart
SOURCE FUNCTION: `consecutiveDaysWithData` (12-35), `_dayHasWearableData` (37-103)
PURPOSE: count of consecutive local days (anchor day included) that have at
least one HR, SpO2, temperature, steps, or sleep-summary record.
FORMULA: walk D, D−1, ... while `_dayHasWearableData`; stop at first empty day;
max 365 lookback.
_dayHasWearableData: any of: heartRateRecords in [day, day+1) OR oxygenRecords OR
temperatureRecords OR stepsRecords OR braceletSleepRecords with endTimeStamp in day.
CONFIDENCE: HIGH

---

## F-12 — Sleep Stage Summary (night window engine)

FORMULA ID: F-12
NAME: Sleep Stage Summary (night segmentation)
SOURCE FILE: lib/core/utils/sleep_stage_summary.dart
SOURCE FUNCTION: `SleepStageSummary.forNight` (91-175), `_loadRawSegments` (206-249),
`_processSegmentsForValidNight` (252-272), `_fillGapsAsAwake` (480-511),
`_discardBeforeLongAwakeGap` (515-545)
PURPOSE: derive the canonical night summary consumed by sleep score, RHR, SpO2:
[start, end], per-stage durations, sleepingTime, stage %s, avg HRV, battery flag.
CONVENTIONS (canonical): stage 0=Wake, −1=REM, −2=Nap, −3=NREM1 Light, −4=NREM3 Deep.
NIGHT WINDOW: [18:00 local D−1, 12:00 local D]. Records selected by
startTs in (nightStart−1, nightEnd); each segment end clamped to nightEnd.
ALGORITHM:

```
1. collect raw segments (start<end, end>start), sorted by start
2. window bounds from segments: minStart; maxEnd = max end; BUT if the last
   maxEnd was a clamped-to-nightEnd segment → maxEnd = last segment's start
3. gap-fill: fill [windowStart, windowEnd) with Wake(0) segments wherever missing
   (including before first / after last segment)
4. expunge: find first continuous Wake run (stage 0, gaps included) >= 1h
   → discard the side (before-run vs after-run) with LESS non-wake sleep
   (>= ties keep AFTER)
5. re-derive bounds from kept segments; gap-fill again
6. durations: sum per stage over filled segments (dur = end − start)
7. totalDuration = Σ max(0, end−start) capped at 16h (57600000 ms); <= 0 → empty
8. avgHrvMs = mean of HrvRecord value>0 in [windowStart, windowEnd] (null if none)
9. batteryDepleted = last BatteryRecord with timestamp < maxEnd+1 has value < 3.0
10. sleepingTime = rem+nap+light+deep (wake excluded)
    pctLight/pctDeep/pctRem/pctNap = stage/sleepingTime*100
    pctAwake = wake/duration*100
```

CONSTANTS: _longAwakeThresholdMs = 3600000 (1h), _maxNightDurationMs = 16h,
sleepBaselineWindowDays = 21 (hardcoded const).
MISSING DATA: no in-window segments → empty summary (all zeros, duration 0,
start/end 0) → sleep score 0, RHR/SpO2 null.
MISSING DATA (partial): a night that is ONLY 1h+ of continuous wake is expunged
entirely (kept empty → null). A night split by a 1h+ awake gap keeps the heavier
side.
EDGE CASES: overlapping segments are merged by cursor-advance (later segment
starts at cursor); a segment that would start before windowStart is clipped;
batteryDepleted considers ANY battery sample (even days old) before maxEnd+1.
ROUNDING: none (int ms throughout).
CONFIDENCE: HIGH
NOTES: this is the single most behavior-rich helper; the Go port must replicate
the two-pass gap-fill + expunge exactly (deterministic).

---

## F-13 — Bedtime Baseline (median + stddev)

FORMULA ID: F-13
NAME: Bedtime Schedule Baseline
SOURCE FILE: lib/core/utils/sleep_stage_summary.dart
SOURCE FUNCTION: `bedtimeBaseline` (357-400)
PURPOSE: median bedtime and variability over the last N nights (default 21,
anchor night excluded by default).
FORMULA:

```
for i in 1..21 (or 0..20 if excludeAnchorNight=false):
  summary = forNight(D−i); skip if empty or batteryDepleted
  normalized = normalizeBedtimeMinutes(hour*60+minute of summary.startTimeStamp)
       // minutes < 720 (before 12:00) → +1440
medianNorm = medianInt(normalized)         // even: round((m1+m2)/2)
medianBed = denormalize(medianNorm)        // >=1440 → −1440
stdDev = sqrt( Σ(n−medianNorm)² / (n−1) )  // sample stddev; n<=1 → 0
```

CONFIDENCE: HIGH

---

## F-14 — Personalized Sleep Duration Baseline

FORMULA ID: F-14
NAME: Personalized Sleep Duration Baseline
SOURCE FILE: lib/core/utils/sleep_stage_summary.dart
SOURCE FUNCTION: `personalizedSleepDurationBaseline` (403-433)
PURPOSE: median effective sleep duration (sleepingTime) over last N nights.
FORMULA: per night, `mins = round(sleepingTime/60000)`; skip empty/batteryDepleted
and mins<=0; targetMinutes = medianInt(mins) (even → round of mean of middle two).
CONFIDENCE: HIGH

---

## F-15 — Sleeping-Time Baseline Stats (min/max/avg)

FORMULA ID: F-15
NAME: Sleeping Time Baseline Stats
SOURCE FILE: lib/core/utils/sleep_stage_summary.dart
SOURCE FUNCTION: `sleepingTimeBaseline` (445-476)
PURPOSE: min/max/avg effective sleep duration over window (display panel).
FORMULA: collect sleepingTime ms per night (skip empty/batteryDepleted, ms>0);
minMs/maxMs = extremes; avgMs = round(mean).
CONFIDENCE: HIGH

---

## F-16 — Session Calories (workout, cumulative counter resolution)

FORMULA ID: F-16
NAME: Workout Session Calories
SOURCE FILE: lib/core/utils/workout_engine.dart
SOURCE FUNCTION: `_resolveSessionCalories` (341-377), `_capSessionCalories` (379-391),
`finalizeSessionCalories` (395-425), `_parseCalories` (759-776)
PURPOSE: derive session kcal from the band's cumulative/residual 0x18 counter.
FORMULA:

```
1st payload with rawCal > 0 → baseline = rawCal; session = 0 (baselineResolved=true)
counter reset (base>0 && rawCal+1 < base && rawCal < prevRaw) → baseline=0; session=rawCal
else session = max(0, rawCal − base)
cap: maxByTime = max(1, ceil(elapsedSec/60 * 15))
     earlyCap = elapsed<=15 ? max(1, ceil(elapsed*0.5)) : maxByTime
     capped = min(session, min(maxByTime, earlyCap))
     no-regression: if capped < prev && prev − capped <= 8 → keep prev
finalize (end of session):
  fromDevice = lastRaw − base (or lastRaw if counter reset) ; capped = min(fromDevice, maxByTime)
```

CONSTANTS: _maxKcalPerMinute=15.0, early cap 0.5 kcal/s for first 15s,
regression tolerance 8 kcal.
CONFIDENCE: HIGH (device-specific; Go engine likely does NOT need this —
workout session kcal is stored per session and consumed by F-04 as sessionKcal).

---

## F-17 — MET Calorie Estimator (workout/sport sessions)

FORMULA ID: F-17
NAME: MET-based Calorie Estimation
SOURCE FILE: lib/core/utils/activity_calorie_estimator.dart
SOURCE FUNCTION: `estimateKcal` (51-57), `estimateForStoredExercise` (62-77),
MET table `_metByStoredPt` (24-47)
PURPOSE: estimate session kcal when the device provides none (manual sessions,
sport-history fallback, provisional UI).
FORMULA:

```
minutes = max(0, durationSec / 60.0)
if minutes <= 0 || weightKg <= 0 → 0
met = metByStoredPt[exercise] ?? 4.0
kcal = met * 3.5 * weightKg / 200.0 * minutes
return round(kcal).clamp(0, 10000)
// weightKg fallback: 70.0 if <= 0 (same default as BRACELET_CONFIG)
```

MET TABLE (by exercise.storedPt, Portuguese): Caminhada 3.5, Corrida 8.3,
Trilha 6.0, Ciclismo 6.8, Natação 6.0, Yoga 2.5, Meditação 1.0, Musculação 3.5,
Pilates 3.0, Aeróbica 6.5, Dança 5.0, Badminton 5.5, Futebol 7.0, Tênis 7.3,
Basquete 6.5, Cricket 5.0, Pingue-pongue 4.0, Corda 11.0, Abdominal 3.8,
Vôlei 4.0, Golfe 4.8, Esporte 6.0. Default 4.0.
INPUTS: exercise id, duration s, weightKg. DEAD INPUTS (declared, unused):
ageYears, heightCm, gender — no age-based max HR exists anywhere.
MISSING DATA: weight 0 → 70 kg; duration <= 0 → 0 kcal.
ROUNDING: round(), clamp [0, 10000].
CONFIDENCE: HIGH
NOTES: consumed by activity_processing_resolver (pending-session fallback),
bracelet_sport_history_importer (0x5C fallback chain: device > provisional >
MET), activity_add_screen (manual estimate). This formula is in-scope for Go
if session kcal is computed server-side; the constants are config candidates.

---

## F-18 — Session Statistics (GPS distance, pace, speed)

FORMULA ID: F-18
NAME: Workout Session Aggregation (haversine distance, pace/speed)
SOURCE FILE: lib/core/utils/activity_repository.dart
SOURCE FUNCTION: `generateActivityStats` (305-363), `_haversineMeters` (365-379),
`averageHeartRateForSession` (252-260)
PURPOSE: finalize stored session metrics from track points + HR samples.
FORMULA:

```
haversineMeters(lat1, lon1, lat2, lon2):
  p = π/180 (0.017453292519943295)
  a = 0.5 − cos(Δlat·p)/2 + cos(lat1·p)·cos(lat2·p)·(1 − cos(Δlon·p))/2
  d = 12742 × 1000 × asin(√a)          // 12742 km = 2× Earth diameter; meters

totalDistance = Σ haversine(consecutive points)
if totalDistance <= 0 && session.distance > 0 → totalDistance = session.distance
durationSec = max(1, (end − start) ~/ 1000)      // end = endTime if > 0 else now
avgSpeed = totalDistance > 0 ? totalDistance / durationSec : 0    // m/s
avgPace  = avgSpeed > 0 ? (1000 / avgSpeed) / 60 : 0              // min/km
maxPace  = maxSpeed > 0 ? (1000 / maxSpeed) / 60 : 0
avgAlt   = Σ altitude / n (0 if none); min/max altitude seeded from first point
maxSpeed = max(point.speed)
avgHR    = round(Σ hr / n) over samples with 0 < hr < 255
```

CONSTANTS: 12742, π/180, HR bound <255 (workout samples), track min distance
12 m (workout_engine), sample cadence 900 ms.
CONFIDENCE: HIGH. `Geolocator.distanceBetween` (workout_engine live distance)
is the same haversine concept but the formula lives in the geolocator package
(external — not provable from this repo).
NOTES: no heart-rate ZONES, no strain/capacity anywhere (verified repo-wide:
no Karvonen, no 220−age; 220 only a validity ceiling). google_polyline_algorithm
is a declared dependency but ZERO imports — unused.

---

## F-19 — Sport History Import (0x5C)

FORMULA ID: F-19
NAME: Band Sport History Parsing
SOURCE FILE: lib/core/utils/bracelet_sport_history_importer.dart
SOURCE FUNCTION: `_parseRecord` (117-185), `_isAlignedAppMatch` (188-202)
PURPOSE: import band sport sessions and match them to app sessions.
FORMULA:

```
periodRaw (ActiveMinutes, seconds) clamp [0, 86400]
durationMinutes = round(periodRaw/60).clamp(1, 1440)
end = start + (durationSeconds > 0 ? durationSeconds : 60) s
distanceMeters = distanceRaw > 50 ? distanceRaw : distanceRaw × 1000   // m vs km heuristic
calories = round(caloriesRaw).clamp(0, 100000)
heart = 30 < hr < 220 ? hr : 0
match: same workMode + |start0x5C − startApp| ∈ [−2min, +5min]; nearest wins
historical dedup: same mode + |start diff| <= 3 min
calories fallback chain: 0x5C > provisional > MET estimate (F-17)
```

CONFIDENCE: HIGH. AMBIGUOUS: the `> 50` meters-vs-km heuristic assumes band
distance is km when small — device-specific.

---

## F-20 — Background Analysis Thresholds (notifications)

FORMULA ID: F-20
NAME: Wearable BG Analyses (alerts)
SOURCE FILE: lib/core/utils/bracelet_bg_analyses.dart
SOURCE FUNCTION: sleep temp analysis (222-258), sleep ratio (176-188),
steps today (291-303)
PURPOSE: push notification triggers (display/alert layer, NOT scores).
FORMULA:

```
sleep temp: avg = mean(temp in sleep window); 7-day baseline if hist >= 20 samples
  alert if avg >= baseline + 0.4 OR avg <= baseline − 0.4  (°C)
sleep ratio: ratio = (sleepingTime/60000) / sleepTarget (default 480 min)
  bands 0.95..1.15 (ideal outside → alert)
steps today: peak of day's StepsRecord.value; alert thresholds 8000/4000
```

CONFIDENCE: HIGH. NOT part of the score graph; listed for completeness
(alert semantics may be wanted by the Go service later).

---

## F-21 — Temperature Card Baseline (UI-only)

FORMULA ID: F-21
NAME: 21-day Temperature Baseline (display layer)
SOURCE FILE: lib/widgets/parameter_cards/temperature_card.dart
SOURCE FUNCTION: `_computeBaselineFromIsar` (278-292), `_baselineWindowBounds` (266-276)
PURPOSE: temperature deviation reference for the temp card + deviation panel.
FORMULA:

```
window = [today − 20d, today]  (21 days, inclusive)
baseline = mean(temperature values with 0 < v < 60 in window)   // °C
deviation = currentTemp − baseline
zones: < −1.0 cold; <= +1.0 normal; <= +1.5 attention; else alert
```

CONFIDENCE: HIGH. IMPORTANT: the ONLY temperature baseline in the app lives in
the UI layer (no core twin) — a candidate to move into the Go engine if
temperature features become product-facing. Validity filter (0, 60) differs
from ingestion filter (30, 45).

---

## Ingestion filters (raw pipeline, bracelet_service.dart)

| Filter | Site | Condition |
|---|---|---|
| HR dynamic array | :273 | `val > 30 && val < 220 && val != 85` (85 = device artifact) |
| HR persist | :285 | `hr > 0` + timestamp gate |
| SpO2 persist | :690 | `spo2 > 70 && spo2 <= 100` (**> 70 EXCLUSIVE** at ingestion; baselines use `>= 70` inclusive at :216/229) |
| Temperature | :959 | `temp > 30 && temp < 45` °C |
| Battery | :1017 | `level > 0 && level <= 100` |
| HRV | :614 | `value > 0` |
| Steps | :467 | `stepsIncremental > 0` + timestamp gate |
| Date sanity | :1738 | year in [2024, now+1] |
| HRV night window | sleep_stage_summary:146 | `> 0` |
| Workout samples | workout_engine:702 | `30 < hr < 220` |

## Supplementary findings (sub-audits)

1. **SLEEP-STAGE MAPPING CONFLICT (HIGH IMPACT — needs device verification)**:
   - Executing code `SleepStageMapper.braceletRawToCanonical`
     (lib/core/utils/sleep_stage_mapper.dart:18-31): raw **1→Light, 2→Deep**,
     3→REM, 0→Wake.
   - Ingestion comment (bracelet_service.dart:768-773, "CORRIGIDO - baseado no
     app oficial"): raw **1=deep, 2=light**.
   - Both introduced in the same port commit (3df6ddc); the JStyle SDK passes
     the stage array through without decoding, so no third source in the repo
     settles it. If the comment is right, pctDeep/pctLight are SWAPPED
     downstream (sleep score quality discount, stage %, baselines, charts).
     Go port: replicate the EXECUTING mapper for parity, gate behind a config
     flag, and verify with a real device before trusting deep/light values.
2. **Instant stress score (UI-only)**: stress_widget.dart:86-100 computes an
   "instant" stress from instantHrvMs/baselineMs via core `fromHrv` but with
   hardcoded `baselineLnSd` fallback **0.15** — core default is **0.22**
   (score_calibration.dart:74; core clamps input to ≥0.20). Divergent results.
   Decision needed: standardize on core's 0.22 or keep 0.15.
3. **Two RHR definitions**: score path = P10 of night HR (wellness_baselines
   :108-110); HR card = mean of lowest 20% of day HR (heart_rate_card:289-292).
4. **isNap thresholds differ**: ingestion marks nap when totalDuration < 3h
   (bracelet_service.dart:889); sleep_widget re-derives nap when sleep window
   < 1h (:288).
5. **avgHrv default diverges**: generated sleep summary defaults avgHrv to 70
   when no HRV (bracelet_service.dart:1326-1344); SleepStageSummary.avgHrvMs
   stays null (sleep_stage_summary.dart:149-151).
6. **Backend day boundary = 03:00 local**: timeseries/hipnograma queries use
   `start_at=T03:00:00&end_at=T02:59:59` (wellness_timeseries.dart:65-72,
   160-165) — the backend aggregates on a 03:00 day while the app scores on
   midnight days. The Go engine must pick one boundary and document the
   mismatch.
7. **vitalTimestampMs** (hr_spo2_param_keys.dart:3-12): seconds→ms conversion
   when ts < 1e10 (pre-2001-09-09) — API param timestamps may arrive in
   seconds.
8. **Device sources**: 'BRACELET' and 'API' are written; 'RING' is NEVER
   written in this repo (read-side preference only); 'FILTERED' is an
   in-memory card remap.
9. **StepsRecord ID includes deviceSource** — same timestamp from API and
   BRACELET coexist (fastHash FNV-1a upsert semantics).
10. **No weekly averaging exists**: weekly/monthly charts plot per-day
    min/max, not means (chart_data.dart:312-340). "Rolling averages" do not
    exist in this codebase outside the stress trend (F-02).

## Cross-cutting facts

- **Timezone**: ALL day/night windows are computed in the DEVICE's local
  timezone (`DateTime(y,m,d)` constructors; `DateTime.fromMillisecondsSinceEpoch`
  without UTC flag). No timezone parameter exists anywhere in the score path.
- **HR validity filter** (shared): 30 < hr < 220 (wellness_baselines.dart:103,
  workout_engine.dart:307/702, instant HR widget:173).
- **SpO2 validity filter**: 70 <= spo2 <= 100 (wellness_baselines.dart:216/229).
- **Steps are cumulative counters**: aggregation = PEAK (max) per day
  (F-04/F-07), not sum.
- **Battery depletion invalidates sleep**: < 3.0% at last sample before night
  end → sleepScore 0.
- **Scores are 0 = "no data"**: 0 never means "bad score"; readiness/sleep ring
  renders 0 as "–" (home_screen).
- **Rounding summary**: `.round()` (half away from zero) everywhere except
  historical sleep avg `.ceil()`, discount sum `.toInt()` (truncation), steps
  `.toInt()` (truncation), calories `.ceil()` (workout parse).
- **Dead config parameters** (declared in ScoreCalibration, never referenced by
  any algorithm): instantFallbackHours, idealStagePctMin, idealStagePctMax,
  highStagePct, batteryDepletedPct (hardcoded 3.0 used instead), nightStartHour,
  nightEndHour (hardcoded 18/12 used instead), rhrBaselineWindowDays (30 used
  instead of 21).
