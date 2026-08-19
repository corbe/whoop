# Wellness Input Contract — ritma-app

**Repository:** noana-org/ritma-app @ `5b1698f` (main)
**Source of truth:** lib/src/isar/db/health_collections.dart (models),
lib/core/scores/*.dart (consumers), bracelet_service.dart (BLE ingestion),
wellness_timeseries.dart (API ingestion).
**Global rule:** timestamps are Unix epoch **milliseconds**. All day/night
windows are computed in the DEVICE LOCAL timezone (no UTC flag anywhere in the
score path — `DateTime(y,m,d)` constructors and
`DateTime.fromMillisecondsSinceEpoch` without `isUtc`). There is NO timezone
parameter in any formula.

## Raw inputs

### HR — HeartRateRecord (health_collections.dart:20-33)
- canonical name: `heart_rate`
- fields: personUuid (str), timestamp (int ms, epoch), value (double, **bpm**),
  deviceSource ("BRACELET" | "API")
- sampling frequency: device-driven (JStyle automatic HR monitoring; BLE sync
  batches; API warm-up 7-day series). No fixed cadence enforced.
- timestamp semantics: sample time, epoch ms, LOCAL-day bucketing.
- timezone: local device.
- nullable: personUuid/timestamp/value all nullable in schema; consumers filter
  `value != null && value > 30 && value < 220` (wellness_baselines.dart:103,
  workout_engine.dart:307,702).
- valid range: (30, 220) bpm EXCLUSIVE (per consumer filters).
- aggregation: nightly P10 (F-05); sleep-window mean not used for HR.
- used by: F-05 (nightly RHR → readiness RHR component), workout samples,
  streak (F-11), charts (display).

### HRV — HrvRecord (health_collections.dart:49-61)
- canonical name: `hrv`
- fields: personUuid, timestamp (ms), value (double, **ms** — key
  `vitals_cardiac_hrv_ms_value` in bracelet_service.dart:643), deviceSource.
- SEMANTICS: value is produced by the JStyle SDK/device (`_saveHrv`
  bracelet_service.dart:569-650 reads SDK fields `hrv`/`HRV`/`value`). Whether
  it is RMSSD, SDNN, or another metric is **UNKNOWN** (device-internal); the
  consumer math (F-02) treats it as RMSSD-like (ln domain, named lnRmssd).
  Document as "device-computed HRV, ms, assumed RMSSD — VERIFY with device
  vendor".
- sampling: device-driven; BLE sync per batch; API warm-up slug
  `variabilidade-de-fc`.
- filters: `value > 0` (stress_score.dart:122, sleep_stage_summary.dart:146).
- no upper bound filter.
- used by: F-02 (stress score; 21-day window daily averages; 15/60/180-min
  instant windows), F-12 (avgHrvMs over sleep window — informational).

### SpO2 raw — OxygenRecord (health_collections.dart:64-76)
- canonical name: `spo2_raw`
- fields: personUuid, timestamp (ms), value (double, **percent 0-100**),
  deviceSource.
- filters: `value >= 70 && value <= 100` (wellness_baselines.dart:216,229).
- used by: F-06 (fallback when no filtered records), charts.

### SpO2 filtered — OxygenFilteredRecord (health_collections.dart:79-89)
- canonical name: `spo2_filtered`
- fields: personUuid, timestamp (ms), value (double, percent).
- semantics: device-filtered SpO2 series (band's own filtering); consumers
  PREFER it over raw (F-06).
- filters: same 70-100 (F-06 first pass).
- used by: F-06 (nightly avg → readiness SpO2 component).

### Temperature — TemperatureRecord (health_collections.dart:92-104)
- canonical name: `temperature`
- fields: personUuid, timestamp (ms), value (double), deviceSource.
- UNIT: **UNKNOWN** from schema. API slug contains 'temp'; chart widgets exist
  (chart_temperature_*.dart). No score consumes it. Likely Celsius (Brazilian
  market) — mark UNKNOWN, verify with device vendor / chart axis units.
- used by: nothing in the score path (display only), streak (F-11).

### Steps — StepsRecord (health_collections.dart:107-120)
- canonical name: `steps`
- fields: personUuid, timestamp (ms), value (double, **count**), calories
  (double, **kcal**), distance (double, **meters?** — see UNITS note),
  deviceSource.
- SEMANTICS: **cumulative daily counter** (per sample: running total of the
  day). Consumers take the PEAK (max) value per day (F-04 aggregateSteps,
  F-07 dailySteps). calories/distance ride along per sample; F-04 takes their
  max too.
- UNITS: calories kcal (workout UI shows kcal), distance likely meters —
  **AMBIGUOUS** (no unit conversion in code; verify with vendor).
- filters: API ingest stores only value > 0 (wellness_timeseries.dart:132);
  baseline loops require steps > 0 to count a sample day.
- used by: F-04 (activity score), F-07/F-08 (personalized steps goal),
  F-11 (streak), charts.

### Battery — BatteryRecord (health_collections.dart:123-134)
- canonical name: `battery`
- fields: personUuid, timestamp (ms), value (double, **percent**),
  deviceSource.
- used by: F-12 batteryDepleted flag: LAST record with
  `timestamp < nightEnd + 1` (sort desc, findFirst) and `value < 3.0`
  (sleep_stage_summary.dart:153-161). NOTE: the sample can be days old; any
  battery sample before the night end counts.

### Sleep stages — SleepStageRecord (health_collections.dart:211-225)
- canonical name: `sleep_stage_segments`
- fields: personUuid, startTs (ms), endTs (ms), stage (int), deviceSource.
- stage encoding (canonical): 0=Wake, −1=REM, −2=Nap, −3=NREM1 Light,
  −4=NREM3 Deep (sleep_stage_summary.dart:9-13). The SDK's raw stage numbers
  are mapped to this canonical set in the BLE ingestion layer (sleep_stage_mapper.dart).
- semantics: half-open intervals [startTs, endTs), endTs > startTs required.
- time window: night = [18:00 local D−1, 12:00 local D]; records selected by
  `startTs > nightStart − 1 && startTs < nightEnd`; endTs clamped to nightEnd.
- used by: F-12 (summary), F-13/14/15 (baselines), hipnograma chart.

### Legacy sleep summaries — BraceletSleepRecord (health_collections.dart:181-207)
- fields: startTimeStamp, endTimeStamp, duration, deepSleepTime,
  lightSleepTime, remSleepTime, wakeSleepTime, unitLengthMinutes,
  arraySleepQuality, isNap, sleepPeriodsJson, ...
- used by: ONLY F-11 (streak counts nights by endTimeStamp). NOT used by any
  score/baseline (the unified SleepStageRecord path replaced it).

### Activity sessions — ActivitySessionRecord (activity_collections.dart)
- canonical name: `activity_session`
- fields: sessionId, status ('completed' matters), startTime (ms),
  calories (kcal), plus average/max HR, distance, pace, speeds, altitudes
  (see sub-audit, workout section).
- used by: F-04 sessionKcal (status='completed', startTime in
  [dayStart, nextDay), calories > 0 summed).

### Workout samples — ActivitySample / TrackPoint
- ActivitySample: sessionId, timestamp (ms), heartRate (bpm, valid 30-220),
  calories, steps, exerciseTimeSec. Cadence: >= 900 ms min interval
  (workout_engine.dart:26), flush batches of 5.
- TrackPoint: sessionId, latitude, longitude, altitude, speed, accuracy,
  timestamp. Track min distance 12 m; distance = sum of Haversine segments
  (Geolocator.distanceBetween).
- used by: activity detail/live screens (display), session kcal aggregation.

### Demographics — LoggedPersonCache
- canonical name: `demographics`
- fields: birthDate (string, yyyy-MM-dd prefix), heightCm (double), weightKg
  (double), gender (string, free text: 'F'/'FEMALE'/'MULHER'/'M'/...).
- derived: ageYears (full years vs now), BMI = kg/(m)^2 (both > 0 required).
- used by: F-10 (priors) → F-01/F-04/F-08/F-09.

## Derived/stateful inputs (from SharedPreferences / Parameter)

| Key | Type | Meaning | Set by |
|---|---|---|---|
| `wellness_bed_time_minutes` | int | target bedtime minute-of-day | F-09 auto-update, user, seed |
| `wellness_sleep_target_minutes` | int | target sleep minutes | F-09, user, seed |
| Parameter.limitMax @ `vitals_activity_pedometer_steps_data_value` | double | steps goal | F-08 auto-update, user |
| `baselineCacheSteps_<uuid>_<yyyyMMdd>` | json | steps baseline cache | F-08 |
| `manualGoalOverrideAt_<uuid>` / `manualSleepOverrideAt_<uuid>` | int ms | manual override marker | user action |
| `lastAutoStepsGoalUpdateAt_<uuid>` / `lastAutoSleepUpdateAt_<uuid>` | int ms | auto-update cooldown | F-08/F-09 |
| `personalizedBaselineSeeded_<uuid>` | bool | seed marker | F-08 |

## Aggregation requirements per consumer

| Consumer | Window | Aggregation |
|---|---|---|
| F-02 stress | 21 days incl. anchor day, local-day buckets | daily mean → mean / ln-sample-stddev / 7d linear-weighted mean |
| F-02 instant HRV | last 15/60/180 min before `date` | geometric mean (exp mean ln) of raw samples |
| F-05 RHR | sleep window [start,end] of F-12 | P10 nearest-rank (floor(n*0.1)) |
| F-05 RHR baseline | 30 prior nights (D−1..D−30) | median of nightly P10 → shrinkage w=n/30 vs prior 65 |
| F-06 SpO2 night | sleep window | mean (filtered preferred, raw fallback) |
| F-06 SpO2 baseline | 30 prior nights | mean of nightly means → shrinkage vs prior 96 |
| F-04 steps day | local civil day | PEAK of counter (max) |
| F-07/F-08 steps | 30 prior days (D−1..D−30) | per-day peak, median of days, shrinkage vs prior |
| F-13 bedtime | 21 prior nights | median of normalized bedtime, sample stddev (n−1) |
| F-14 duration | 21 prior nights | median of rounded sleepingTime minutes |
| F-15 duration stats | 21 prior nights | min/max/round(mean) of sleepingTime ms |
| F-01 sleep score | night window | per-stage sums, % of sleepingTime |
| F-03 readiness | D (sleep), D−1..D−4 (sleep history), D−1..D−3 (fatigue), 30 nights (RHR/SpO2 baselines) | see formulas |

## Valid-range summary (consumer-enforced)

- HR: 30 < value < 220 bpm (ingestion array filter ALSO excludes exactly 85 —
  bracelet_service.dart:273, a device artifact)
- HRV: value > 0 ms (no upper bound)
- SpO2: ingestion `> 70` EXCLUSIVE and `<= 100` (bracelet_service.dart:690);
  baseline window uses `>= 70` INCLUSIVE (wellness_baselines.dart:216,229) —
  a sample of exactly 70 is rejected at ingestion but accepted in baselines
- Temperature: ingestion `30 < t < 45` °C (bracelet_service.dart:959);
  display baseline filter `0 < t < 60` (temperature_card.dart:234)
- Battery: 0-100 % (depleted flag < 3.0); ingestion `> 0 && <= 100`
- Steps: value >= 0; count-only-if->0 for baseline samples
- Sleep stage: endTs > startTs; duration cap 16h per night
- Score range: 0-100 (0 = no data)

## Day-boundary semantics (critical)

- APP (score/baseline/streak) day = LOCAL MIDNIGHT (all DateTime(y,m,d)
  constructors).
- BACKEND timeseries/hipnograma queries use **03:00 local** as the day
  boundary (`start_at=T03:00:00&end_at=T02:59:59`,
  wellness_timeseries.dart:65-72,160-165). The Go engine must decide which
  boundary is canonical for ingestion vs calculation and document the
  mismatch (a sample at 01:00 belongs to "yesterday" for the backend and
  "today" for the app scores).

## Explicit UNKNOWNS (do not guess)

1. HRV metric type (RMSSD vs SDNN vs vendor-specific) — device-internal.
2. Temperature unit (Celsius assumed, UNVERIFIED).
3. Steps distance unit (meters assumed, UNVERIFIED).
4. Exact device sampling cadence (device-internal).
5. Whether the band's SpO2 "filtered" series differs algorithmically from raw
   (device-internal).
