# Wellness Engine — HML Input Mapping (STAGE 19A)

Maps every input the official Dart calculation consumes to its real HML
source, and to the Go canonical DayInput (STAGE 18.2 format). This is the
contract the shadow input-provider adapter must implement.

## Current HML input path (verified)

```
wearable (bracelet) ── raw packets ──► uploader / IoT gateway
        ──► backend SQS consumer ──► Redis TimeSeries (per person/param)
        ──► app pulls ~21 days: GET /person/{uuid}/{slug}/timeseries/json/
              (slugs: batimento-cardiaco, oxigenacao, variabilidade-de-fc,
               passos, temperatura-axilar, temperatura-extremidade,
               hipnograma)  ──► Isar collections
        ──► Dart wellness services (Isar + app-local state) ──► official score
```

The app writes API-sourced records with `deviceSource='API'` and the RAW
values (HR bpm, SpO2 %, HRV ms, steps value, sleep stage ints preserved
verbatim from the hipnograma payload — the 1→Light/2→Deep question lives in
the DISPLAY mapper, not in the stored data).

## Source matrix (19A.1)

| input | source | class |
|---|---|---|
| sleep stage segments | backend hipnograma timeseries → Isar (raw ints) | BACKEND_NORMALIZED (raw preserved) |
| HR | backend batimento-cardiaco → Isar | BACKEND_NORMALIZED |
| HRV | backend variabilidade-de-fc → Isar | BACKEND_NORMALIZED |
| SpO2 | backend oxigenacao → Isar | BACKEND_NORMALIZED |
| steps | backend passos → Isar (VALUE ONLY — no calories/distance) | BACKEND_NORMALIZED |
| temperature | backend temperatura-* → Isar | BACKEND_NORMALIZED (unused by formulas) |
| battery | BLE SDK only (bracelet_service.dart:1023) | APP_LOCAL |
| activity sessions/kcal | SDK (activitySessionRecords) | APP_LOCAL |
| bracelet calories/distance | SDK-side steps records (API records carry 0) | APP_LOCAL / AMBIGUOUS |
| goals (steps/sleep) | Isar Parameter + SharedPreferences | APP_LOCAL (per-device) |
| demographics (prior steps/bed/target) | LoggedPersonCache | APP_LOCAL (birthdate/gender/height/weight) |
| prefs (bed/target/manual override/cooldown) | SharedPreferences | APP_LOCAL |
| RHR/SpO2 baselines | DERIVED in-app from 30 nights of Isar HR/SpO2 | DERIVED |
| sleep/stress baselines | DERIVED in-app from Isar history | DERIVED |

## Field mapping (19A.3)

Canonical field → source → status. Timezone semantics: all backend samples
are epoch-ms; the app buckets in device-local time (HML = America/Sao_Paulo).
The canonical fixture declares `timezone` and the harness buckets in
`time.Local`; the shadow adapter MUST run with TZ=America/Sao_Paulo and
verify the anchor-day wall-clock alignment.

| canonical field | HML source | unit | missing-data | window | status |
|---|---|---|---|---|---|
| segments | hipnograma timeseries (transitions [t,stage] or {startTime,endTime,type}) | raw stage ints | empty night = no segments | anchor night [18:00 D-1, 12:00 D] | MAPPED |
| hrv (raw samples) | variabilidade-de-fc | ms | absent → avgHrv null, stress insufficient | 21+ days | MAPPED |
| steps | passos (value only) | steps | absent → no activity | day D | MAPPED (calories MISSING) |
| battery | SDK only | % | absent → not depleted | anchor night | NEEDS_ADAPTER |
| session_kcal | SDK activity sessions | kcal | absent → 0 | day D | NEEDS_ADAPTER |
| goal_steps_current | Isar Parameter limitMax | steps | absent → prior 7500 | current | NEEDS_ADAPTER |
| goal_step_samples | Isar steps D-1..D-30 | steps | absent → no update | 30 days | MAPPED (from steps) |
| baseline_nights | hipnograma D-1..D-30 | segments | empties allowed | 30 nights | MAPPED |
| last_night_rhr / rhr_baseline | DERIVED (HR 30 nights) | bpm | null → component skipped | 30 nights | MAPPED (derivation reproducible) |
| spo2_tonight / spo2_baseline | DERIVED (SpO2 30 nights) | % | null → component skipped | 30 nights | MAPPED |
| sleep_history | DERIVED (scoreOnly D-1..D-4) | score | 0 = no data | 4 nights | MAPPED |
| goal_prior_steps / max | demographic prior / 15000 | steps | constant | — | MAPPED |
| sleep bed/target currents | prefs (seeded 1320/480) | minutes | absent → defaults | current | NEEDS_ADAPTER |
| goal cooldown/override timestamps | prefs | epoch-ms | absent → none | current | NEEDS_ADAPTER |
| demographics | LoggedPersonCache | — | absent → demo M/36 | current | NEEDS_ADAPTER |

**Calories/distance on steps (activity kcal)**: the backend `passos` payload
carries only the step value. The official activity score derives
`totalKcal = wearableDayKcal + sessionKcal` where wearableDayKcal comes from
the steps record's `calories` field — present ONLY on SDK-written records.
For API-synced persons (reinstall/multi-device) the official path already
produces different kcal than SDK-synced ones. Status: **AMBIGUOUS** — must be
resolved on HML by comparing a real day's official activity breakdown against
what the backend can supply (see `wellness-hml-shadow-design.md` §validation
cohort). If backend calories are unavailable, the shadow must record the
official `totalKcal` (from the DailyScore upload, which carries activity
scores) and treat kcal inputs as NEEDS_ADAPTER — never fabricate them.

**Goal state is per-device app-local** — a reinstall resets to demo priors
until auto-update rebuilds from 30 days of history. The shadow cannot
reconstruct the official goal state from the backend alone; it must capture
it (below).

## History reconstruction (19A.4)

For day D the Go shadow needs, from the backend:

- sleep segments: D-4..D (readiness history) + D-1..D-21 (F-09 sleep goals) +
  D-1..D-30 (RHR/SpO2 windows) — the hipnograma endpoint serves arbitrary
  ranges; one fetch D-30..D covers everything.
- HR/SpO2/HRV samples: D-30..D (30 nights for RHR/SpO2 baselines + 21 days
  for the stress baseline + the anchor night for avgHrv).
- steps: D-1..D-30 (goal samples) + day D (activity).

The warmup already pulls ~21 days; the shadow adapter pulls D-30..D (31
days) — the same data the app would hold after warmup, and exactly the
windows the Dart services iterate. **The Dart calculation on HML is
effectively stateless w.r.t. history beyond 30 days** (all baselines are
derived from ≤ 30-night windows read from Isar); a 31-day pull reproduces
the same effective state.

## Goal state capture (19A.5)

The shadow input provider must receive, per person, the CURRENT app goal
state: steps goal (Parameter limitMax), sleep bed/target (prefs), manual
override timestamps, last auto-update timestamps, and demographics. Options
for capturing (choose at 19B): (a) the app uploads its goal state with the
DailyScore upload; (b) the backend stores goal state after first sync. Until
then, the shadow adapter accepts a goal-state JSON sidecar exported from the
app (dev tooling). The Go shadow records its hypothetical goal updates in the
shadow store only; official state is never written.
