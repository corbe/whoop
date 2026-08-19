# Wellness Formula Dependency Graph — ritma-app

**Repository:** noana-org/ritma-app @ `5b1698f` (main)
**Method:** only edges PROVEN by source code (file:line cited). Formula IDs
reference docs/wellness-formula-audit.md.

## Raw inputs (leaf nodes)

| Raw input | Collection (lib/src/isar/db/health_collections.dart) | Produced by |
|---|---|---|
| HR samples (bpm) | HeartRateRecord (L20-33) | BLE sync (bracelet_service.dart), API warm-up (wellness_timeseries.dart), instant HR widget |
| HRV samples (ms) | HrvRecord (L49-61) | BLE sync `_saveHrv` (bracelet_service.dart:569-650, value from SDK `hrv`/`HRV`/`value` field) |
| SpO2 raw (%) | OxygenRecord (L64-76) | BLE sync, API warm-up |
| SpO2 filtered (%) | OxygenFilteredRecord (L79-89) | BLE sync (device-filtered series) |
| Temperature | TemperatureRecord (L92-104) | BLE sync, API warm-up |
| Steps counter (+calories+distance) | StepsRecord (L107-120) | BLE sync, API warm-up (value>0 only) |
| Battery (%) | BatteryRecord (L123-134) | BLE sync |
| Sleep stage segments | SleepStageRecord (L211-225), stage 0/-1/-2/-3/-4 | BLE sync, hipnograma API |
| Sleep summaries (legacy) | BraceletSleepRecord (L181-207) | BLE sync (used ONLY by streak F-11) |
| Activity sessions (kcal) | ActivitySessionRecord (activity_collections.dart) | WorkoutEngine stop / manual |
| Workout HR samples | ActivitySample (activity_collections.dart) | WorkoutEngine `_recordSample` (>=900ms cadence) |
| GPS track | TrackPoint | WorkoutEngine (>=12m steps) |
| Demographics (age/BMI/gender) | LoggedPersonCache | account profile |
| Device battery | BatteryRecord | BLE sync |

## Dependency DAG (formula IDs per audit doc)

```
HeartRateRecord ──┬──> [nightly P10] ──> F-05 nightlyRestingHr
                  │                          │  (30 nights)
                  │                          ▼
                  │                   F-05 rollingRestingHr (median+shrinkage) ──┐
                  │                                                              │
SleepStageRecord ─┴──> F-12 SleepStageSummary.forNight ──┬──> F-05 RHR tonight   │
                        (gap-fill, 1h expunge, 16h cap)  ├──> F-06 SpO2 tonight  │
                        │                                ├──> F-13 bedtime median│
                        │                                ├──> F-14 duration med. │
                        │                                └──> F-15 min/max/avg   │
                        │                                                       │
Oxygen(Filtered)Record ─┴──> F-06 nightlyAvgSpo2 ──> F-06 rollingNightSpo2 ──────┤
                        │                                                       │
BatteryRecord ──────────┴──> F-12 batteryDepleted flag                           │
                                                                                 │
HrvRecord ────────────────> F-02 StressScore (21d baseline, ln-SD,               │
                            7d weighted trend, z→sigmoid, instant HRV)          │
                                                                                 │
                                                                                 ▼
                                ┌────────────────────────────────────────────────┐
                                │             F-01 SleepScore                    │
Demographics ──> F-10 Priors ──>│  prefs bed/target (or F-08/F-09 auto-learn)    │
StepsRecord ────> F-07 dailySteps│  = 100 − (bedtime + duration + quality)       │
                                └───────────────┬────────────────────────────────┘
                                                │ scoreOnly(D−1..D−4)
                                                ▼
                                F-03 ReadinessScore
                                components: sleep(0.35) + recovery=100−stress(0.25)
                                + rhr(0.15)? + spo2(0.10)? + fatigue(0.15)?
                                caps by todaySleepScore (≤30→35, ≤40→45, ≤50→58, ≤60→72)
                                                │
                                                ▼
StepsRecord ──> F-04 ActivityScore: peak steps → goalKcal(0.04/step, ±10, 150-800)
                                + session kcal; dayTarget from readiness(0.55/55)
                                score = 100*totalKcal/goalKcal
                                                │
                                                ▼
                                WellnessScores.calculateRings → 3 rings
                                (sleep, readiness, activity + zone band)
```

## Execution order constraints (topological)

1. F-12 (night summary) MUST run before: F-01 (sleep score), F-05 (RHR),
   F-06 (SpO2), F-13/14/15 (sleep baselines).
2. F-01 MUST run before F-03 (readiness needs sleep today + D−1..D−4).
3. F-02 MUST run before F-03 (stress gates readiness; recovery component).
4. F-05/F-06 MUST run before F-03 (optional components) — each needs 30 prior
   nights, which recursively need F-12 per night.
5. F-03 MUST run before F-04 (readiness gates activity's dayTargetPercent).
6. F-08/F-09 (auto-update of goals) run BEFORE scores in calculateRings
   (wellness_scores.dart:58) — they mutate prefs/Parameter used by F-01/F-04.
7. F-10 (priors) is a leaf dependency of F-01 (bed/target default), F-04
   (goal steps default), F-08 (prior), F-09 (prior bed/target).

## Cycles

NONE in the pure calculation graph. The only feedback loop is through
stateful side effects: F-08/F-09 auto-update MUTATES the goal used by
F-01/F-04 for the SAME day (run first in calculateRings). The Go engine
mirrors the app: `CalculateDayDetailed` runs goal updates BEFORE scores and
feeds the EFFECTIVE goals into F-01 (bed/target) and F-04 (goalSteps) —
see wellness-engine/internal/engine. The wall-clock cooldown/manual-override
gates make `Now` an EXPLICIT input of the pure goals package
(internal/goals) — the persistence layer must supply the real wall-clock.

## Execution order (verified, STAGE 11-13)

1. Goal auto-update F-08 (steps) + F-09 (sleep) — event-driven at the START
   of every ring calculation (wellness_scores.dart:58), throttled by the
   7-day cooldown + 30-day manual-override block. Updates fire from
   PROVISIONAL confidence (7+ samples; oracle cases goal_s5/goal_t5).
2. F-12 night → F-01 sleep (uses effective bed/target).
3. F-02 stress (uses HRV daily averages).
4. F-03 readiness (gated by F-01 + F-02; optional F-05/F-06 components).
5. F-04 activity (uses effective goalSteps from F-08 + readiness from F-03).
6. Metadata (formula versions, config_hash, engine_version) + explanations
   attached last; never feed back into math.

## Notes

- F-16 (session calories) is an input producer (activity session kcal), not a
  score formula; it runs at workout time (device side).
- The chart/weekly/monthly aggregation code (providers/chart_data.dart,
  widgets/chart_*.dart) reads the same raw collections but only for display;
  it does NOT feed scores (see wellness-formula-audit.md classification,
  section "Display-only").
- No formula depends on TemperatureRecord, BloodPressureRecord, GlucoseRecord
  or WeightRecord — stored but unused by scores (legacy/storage-only).
