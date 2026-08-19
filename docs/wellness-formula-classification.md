# Wellness Formula Classification — ritma-app

**Repository:** noana-org/ritma-app @ `5b1698f` (main)
**Method:** every item cites file:line. Equivalence is only claimed where code
proves it (see J).

## A. RAW METRICS (stored, ingested from device/API)

| Metric | Collection | Unit | Source |
|---|---|---|---|
| HR samples | HeartRateRecord (health_collections.dart:20) | bpm | BRACELET / API |
| HRV samples | HrvRecord (health_collections.dart:49) | ms (SDK-computed) | BRACELET / API |
| SpO2 raw | OxygenRecord (health_collections.dart:64) | % | BRACELET / API |
| SpO2 filtered | OxygenFilteredRecord (:79) | % | **no writer in repo** (see J) |
| Temperature | TemperatureRecord (:92) | ºC (display) | BRACELET / API |
| Steps counter (+cal+distance) | StepsRecord (:107) | count / kcal / m? | BRACELET / API |
| Battery | BatteryRecord (:123) | % | BRACELET |
| Sleep stage segments | SleepStageRecord (:211) | ms intervals, stage −4..0 | BRACELET / API hipnograma |
| Legacy sleep summary | BraceletSleepRecord (:181) | ms | BRACELET (streak only) |
| Activity session | ActivitySessionRecord (activity_collections.dart:7) | kcal, HR, dist, pace | workout engine |
| Workout HR samples | ActivitySample | bpm | WorkoutEngine ≥900ms |
| GPS track | TrackPoint | lat/lon/alt/speed | geolocator |
| Blood pressure / glucose / weight | BloodPressureRecord/GlucoseRecord/WeightRecord | UNKNOWN | stored, unused by scores |

## B. NORMALIZED METRICS (derived from raw, same scale domain)

- Daily HRV average per local day (stress_score.dart:132-144) — mean of raw ms.
- `ln(hrv)` values (stress_score.dart:15,41) — log-domain normalization.
- Stage percentages pctLight/pctDeep/pctRem/pctNap over sleepingTime, pctAwake
  over duration (sleep_stage_summary.dart:78-86).
- Normalized bedtime (minutes < 720 → +1440) (sleep_stage_summary.dart:346-349).
- HR filter 30–220, SpO2 filter 70–100 (wellness_baselines.dart:103,216,229).
- Day aggregation of steps: PEAK (max) of cumulative counter (activity_score.dart:55-78, wellness_baselines.dart:55-83).

## C. BASELINES (rolling/personal references)

| Baseline | Formula | Window | Confidence |
|---|---|---|---|
| Nightly RHR (P10) | wellness_baselines.dart:86-111 | sleep window | — |
| RHR rolling baseline | :113-151 median + shrinkage vs 65 | 30 nights | none/early/provisional/good/optimal |
| Night SpO2 avg | :153-164 mean | sleep window | — |
| SpO2 rolling baseline | :166-200 mean + shrinkage vs 96 | 30 nights | same |
| Personalized steps goal | personalized_lifestyle_baseline.dart:161-223 median + shrinkage vs demographic prior | 30 days | same |
| Bedtime baseline | sleep_stage_summary.dart:357-400 median + sample stddev | 21 nights | same |
| Personalized sleep duration | :403-433 median of rounded minutes | 21 nights | same |
| Sleeping-time stats (min/max/avg) | :445-476 | 21 nights | display |
| Stress baseline (HRV mean + lnSd) | stress_score.dart:155-157 | 21 days incl. anchor | via minDaysRequired=5 |
| Demographic priors (steps/bedtime/target) | demographic_prior.dart:12-74 | — | — |

## D. DERIVED METRICS (per-day physiological values)

- nightlyRestingHr (P10) — wellness_baselines.dart:86
- nightlyAvgSpo2 — wellness_baselines.dart:153
- avgHrvMs over night window — sleep_stage_summary.dart:139-151
- dailySteps (peak) — wellness_baselines.dart:55
- sessionKcal per day (completed sessions) — activity_score.dart:193-210
- trendMs (7d linearly weighted HRV mean) — stress_score.dart:69-86
- instantHrvMs (geometric mean 15/60/180min) — stress_score.dart:169-182
- sleepHistoricalAvg (ceil mean of D−1..D−4) — readiness_score.dart:198-212
- fatigueAvgSleep (round mean D−1..D−3) — readiness_score.dart:247-258
- sleepingTime (rem+nap+light+deep) — sleep_stage_summary.dart:75-76

## E. COMPONENT SCORES

| Component | Formula | Range |
|---|---|---|
| sleepComponent (today×0.7 + history×0.3) | readiness_score.dart:57-62 | 0–100 |
| recoveryComponent (100 − stress) | readiness_score.dart:216 | 0–100 |
| rhrComponent (ratio vs baseline) | readiness_score.dart:97-104 | 0–100 |
| spo2Component (delta vs baseline / absolute) | readiness_score.dart:106-123 | 0–100 |
| fatigueComponent (piecewise lerp of avg sleep) | readiness_score.dart:64-78 | 0–100 |
| sleep discounts: bedTimeDiscount, targetSleepDiscount, qualityDiscount | sleep_score.dart:39-93 | see F-01 |

## F. COMPOSITE SCORES

| Score | Composition | Range |
|---|---|---|
| Sleep score | 100 − (quality + bedtime + duration discounts) | 0–100 |
| Stress score | sigmoid(z) of ln-HRV trend vs baseline | 0 (no data) / 12–95 |
| Readiness | weightedBlend(sleep .35, recovery .25, rhr .15?, spo2 .10?, fatigue .15?) + caps by today's sleep | 0–100 |
| Activity | 100 × totalKcal / goalKcal | 0–100 |
| Day target % (activity) | readiness×0.55 + 55×0.45, clamp [30,90]; 100 if readiness 0 | 30–90/100 |
| Zone band | dayTarget ± 10 | — |

## G. CLASSIFICATION RULES (threshold-based verdicts)

- Battery depleted (<3.0% last sample before night end) → sleep score 0
  (sleep_stage_summary.dart:153-161).
- Sleep analysis codes msg1/msg2/msg3 (sleep_score.dart:95-134): bedtime
  lateness bucket 0–4, duration bucket 0–4, stage-quality bucket 0–5
  (display/explanation codes).
- Stage-quality discount buckets (sleep_score.dart:151-157): pct<10 → 5,
  <15 → 4, <20 → 3, >27.5 → 2.
- Readiness caps by today's sleep (readiness_score.dart:80-95): ≤30 → 35,
  ≤40 → 45, ≤50 → 58, ≤60 → 72.
- BaselineConfidence (wellness_baselines.dart:27-33): ≥30 optimal, ≥14 good,
  ≥7 provisional, ≥1 early.
- SpO2 absolute bands (readiness_score.dart:115-122): ≥96 full, ≥94, ≥90.
- RHR zero ratio 1.12 (readiness_score.dart:101).
- HR/SpO2 validity filters (30–220 / 70–100).
- 1h+ continuous awake → night expunge rule (sleep_stage_summary.dart:331,515-545).

## H. DISPLAY-ONLY CALCULATIONS (do not feed scores)

Full inventory with citations in the display-layer sub-audit
(see docs/golden/oracle provenance + task-2 report). Highlights:

- Chart min/max ranges + y-axis normalization (chart_*.dart,
  chart_parameter_limits.dart).
- Weekly/monthly aggregation (chart_data.dart) — reads same raw collections
  for charts only.
- HR/SpO2 card derived stats: daily average, bottom-20% percentile
  (heart_rate_card.dart:280-293, spo2_card.dart:274-294 hourly means).
- Sleep widget HRV avg + nap heuristic (<1h) (sleep_widget.dart:288,324-339).
- Sleep breakdown panel ideal-stage markers: REM ideal 20–25, deep ideal max 20
  (sleep_score_breakdown_panel.dart:29-34) — hardcoded, duplicates dead
  calibration fields.
- Duration formatting (date_time_utils.dart:1-5), session duration fallbacks
  (activities_screen.dart:200-204, activity_detail_screen.dart:122-126),
  distance km formatting.
- SleepStageBar ideal-range bars (sleep_stage_bar_widget.dart:78-79).
- 15-min SpO2 means (chart_spo2_daily_chart.dart:26-39).

## I. LEGACY / UNUSED CALCULATIONS

- OxygenFilteredRecord / HeartRateFilteredRecord: collections exist, READ by
  F-06 and cards, but **NOTHING writes them** in ritma-app (verified repo-wide:
  no `.put`/`.putAll` on those collections outside generated code). F-06's
  filtered branch is therefore dead at runtime → night SpO2 always comes from
  raw OxygenRecord. The 'FILTERED' deviceSource is an in-memory remap in the
  cards (heart_rate_card.dart:234, spo2_card.dart:235).
- BraceletSleepRecord: legacy sleep summaries, only consumed by streak F-11.
- BloodPressureRecord / GlucoseRecord / WeightRecord: stored, no consumer.
- Dead calibration parameters (see formula-configuration-decisions.md §3).
- Instant HR/SpO2 measurement widgets: save last valid sample only
  (bracelet_instant_hr_measurement_widget.dart:279-293); the ECG animation is
  cosmetic.
- `_sampleMinIntervalMs=900` etc. are workout-engine constants (device layer).

## J. DUPLICATED FORMULAS (proven by code, both sites quoted)

Core-vs-core:
1. **Steps peak aggregation** duplicated:
   - activity_score.dart:55-78 (`aggregateSteps` — prefers BRACELET→RING→rest)
   - wellness_baselines.dart:55-83 (`dailySteps` — prefers BRACELET→rest)
   - chart_data.dart:56-78 (`aggregateDailyStepsMetrics` — display, adds
     calories/distance peaks, bracelet-pref 45-54)
   Semantics equal (peak of cumulative counter); device preference differs
   slightly (activity prefers RING as second choice; baselines do not).
   NOT consolidated — the small preference delta matters.
2. **Goal-steps parameter read** duplicated:
   - activity_score.dart:150-159
   - personalized_lifestyle_baseline.dart:462-476
   - activity_widget.dart:130-146 (display)
   Same key `vitals_activity_pedometer_steps_data_value`, same limitMax
   semantics. Safe to consolidate in Go.
3. **Duration formatting** duplicated: date_time_utils.dart:1-5,
   sleep_widget.dart (`_formatHmCompact`), activities_screen.dart:261-265,
   activity_detail_screen.dart:221-227 (display; irrelevant to Go).
4. **Sleep duration fallback** duplicated: activities_screen.dart:200-204,
   activity_detail_screen.dart:122-126 (display).
5. **SpO2 mean over window** patterns repeated (nightly avg vs card hourly vs
   chart 15-min) — same mean math, different buckets (display).
6. **Sleep quality discount thresholds** — the `idealStagePct*` calibration
   fields (dead) vs hardcoded 20/25 in sleep_score_breakdown_panel.dart:29-34 —
   VALUES agree (20–25%), but the panel hardcodes and the algorithm ignores
   them. Ambiguous intent (see audit F-01 NOTE). Display ALSO adds light
   40–50 and deep 15–20 ideal ranges (sleep_widget.dart:1112-1135,
   sleep_score_breakdown_panel.dart:29-34) that core never uses, and core's
   over-high triggers (REM 27.5, deep 25) differ from display's (REM 25,
   deep 20) — divergent constants across 3 sites (D6).
7. **RHR: two different formulas for the same concept** (D1):
   - Score path: P10 of NIGHT HR — wellness_baselines.dart:108-110
   - HR card: mean of lowest 20% of DAY HR — heart_rate_card.dart:289-292
   The Go engine must decide which is canonical (scores use P10).
8. **Instant stress score divergence** (D7): stress_widget.dart:86-100 calls
   core `StressScoreAlgorithm.fromHrv` (good) but hardcodes
   `baselineLnSd: 0.15` fallback vs core `defaultLnSd = 0.22`
   (score_calibration.dart:74). Core clamps input to ≥0.20, so 0.15 → 0.20
   vs 0.22 produce different instant scores. AMBIGUOUS — standardize.
9. **Temperature baseline: UI-only** (D9): temperature_card.dart:278-292
   computes a 21-day mean baseline with NO core counterpart
   (wellness_baselines.dart covers HR/SpO2/steps only). The single most
   important formula living only in the UI layer.
10. **Today-target scaling re-implemented** (D3): activity_widget.dart:169
    recomputes `round(goalSteps·dayTargetPct/100)` while core computes
    `todayTargetKcal` with round-to-10 (activity_score.dart:23-26). Display
    defaults 7000/280 also hardcode core values (D4).
11. **Nap heuristic**: ingestion `isNap = totalDuration < 3h`
    (bracelet_service.dart:889) vs display `sleep window < 1h`
    (sleep_widget.dart:288) vs stored field read in export
    (health_data_export_service.dart:240). Three definitions (D13).
12. **avgHrv default**: generated sleep summary falls back to 70
    (bracelet_service.dart:1326-1344) vs SleepStageSummary null
    (sleep_stage_summary.dart:149-151).
13. **Range-chart Y-scale families** (D11): per-parameter constants duplicated
    across chart widgets; `alignMinMaxSeries` verbatim ×3
    (chart_heart_rate_range_chart.dart:45-58, spo2:38-51, temperature:38-51);
    battery icon thresholds ×2 (home_screen.dart:1394-1402,
    activity_start_screen.dart:649-658).

## Equivalence claims NOT made

- The ritma-app readiness/sleep/stress/activity formulas have NO counterpart
  implementation anywhere else (checked: noana-wellness-app has only the upload
  contract; noana-front-app-code has no such code). "Paridade Noana Fase A"
  comments in score_calibration.dart:4 refer to code that is not available in
  any local repo — equivalence with the original Noana implementation CANNOT be
  proven from available sources.
