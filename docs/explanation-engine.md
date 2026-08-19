# Explanation Engine — RITMA Go Wellness Engine

**Status:** implemented (STAGE 13) in `wellness-engine/internal/explain`.
**Purpose:** machine-readable answers to "why did this score equal X?" —
built ONLY from intermediates the formulas actually used. No medical
interpretation, no invented causal language, no fabricated scores.

## Model

```go
type Explanation struct {
    Score          int
    FormulaKey     versioning.Key
    FormulaVersion int
    ConfigHash     string
    EngineVersion  string
    CalculatedAt   time.Time
    Components     []Component   // key, raw, baseline, normalized, weight, contribution
    Steps          []Step        // linear trace (name → value)
    Warnings       []Warning     // operational pipeline flags
    Missing        []MissingReason
}
```

Fields are only populated when applicable (no fake/null placeholder spam).

## Per-formula contents

### Sleep (F-01)

Components: `bedtime` / `duration` / `stage_quality` discounts (raw values +
analysis codes msg1/msg2/msg3 as normalized values).

Steps trace the discount model:
`bedtime target → sleep target → actual bedtime → sleeping minutes →
pct_rem/pct_deep/pct_light → bedtime_discount → duration_discount →
stage_quality_discount → total_discount_pre_truncation →
total_discount_truncated → score_pre_clamp`.

Recomposition: `score = clamp(100 − trunc(quality + bed + target), 0, 100)`.
Known quirks are reflected, not cleaned:
- the inclusive `<= somewhat` boundary (the +90min case uses the light
  coefficient 0.4);
- the dead early-bedtime path (early coef0 never multiplies a nonzero
  discount);
- degenerate-window nights (nightEnd-clamped segment) → `WARN_NIGHT_DEGENERATE_WINDOW`.

### Stress (F-02)

Steps trace the log-domain pipeline: `baseline_ms → baseline_ln_sd →
trend_ms_7d_weighted → observed_ms → sanitized_ms → z → score_pre_round`.
No "healthy/dangerous" labels — the source defines none.

Recomposition: `z = (ln(baseline) − ln(sanitized))/lnSd` (clamped, or −0.4 at
the 2× short-circuit); `logistic = 1/(1+exp(−0.72(z−2)))`;
`raw = 12 + 83·logistic` (clamped 12..95); `score = round(raw).clamp(0,100)`.

### Readiness (F-03)

Components: `sleep`, `recovery`, and (when present) `rhr`, `spo2`, `fatigue —
each with normalized value, weight, contribution (= normalized × weight), and
raw/baseline values for rhr (last-night RHR vs baseline) and spo2 (tonight vs
baseline). `fatigue` carries the avg-sleep raw.

Steps: `sleep_historical_avg → blend_weighted_sum → blend_total_weight →
blended_pre_round → blended → today_sleep_score` + `cap_applied` when the
cap fired.

Recomposition: `blended = round(Σ normalized·weight / Σ weight)`;
`total = min(blended, cap(today_sleep))` (caps 35/45/58/72; only ever lower).
Test `TestReadinessExplanationRecomposes` proves the explanation recomposes
the golden 78 and the capped 58.

### Activity (F-04)

Components: wearable kcal, session kcal, total kcal, goal kcal, goal steps,
day target %, today-target kcal.

Recomposition: `score = round(100 · totalKcal / goalKcal).clamp(0,100)`.
The explanation identifies WHICH goal value was used (`goal_steps` /
`goal_kcal`) — after a goal update (STAGE 11), the effective goal is what
appears here.

## Missing-data reason codes (no fabricated scores)

| Code | When |
|---|---|
| `SLEEP_DATA_UNAVAILABLE` | empty night summary (duration 0) |
| `SLEEP_INVALID_BATTERY_DEPLETED` | battery < 3% before night end → score 0 |
| `INSUFFICIENT_HRV_DAYS` | < minDaysRequired (5) daily HRV averages |
| `INSTANT_HRV_UNAVAILABLE` | no HRV in the 15/60/180 min windows |
| `READINESS_GATED_NO_STRESS` | stressScore ≤ 0 → readiness not computed |
| `READINESS_GATED_NO_SLEEP` | todaySleepScore ≤ 0 → readiness not computed |
| `RHR_BASELINE_UNAVAILABLE` | no nightly RHR or baseline → rhr component absent |
| `SPO2_BASELINE_UNAVAILABLE` | no nightly SpO2 → spo2 component absent |
| `FATIGUE_DATA_UNAVAILABLE` | no sleep scores in D−1..D−3 → fatigue absent |
| `ACTIVITY_DATA_UNAVAILABLE` | no steps/sessions (total kcal 0) |

## Warnings (operational, not medical)

| Code | When |
|---|---|
| `WARN_BATTERY_DEPLETED` | battery < 3% (sleep invalidated) |
| `WARN_NIGHT_DURATION_CAPPED` | night > 16h truncated (per-stage sums uncapped) |
| `WARN_NIGHT_DEGENERATE_WINDOW` | zero-width window from nightEnd-clamped segment |
| `WARN_INSTANT_HRV_UNAVAILABLE` | instant HRV missing (readiness display only) |

## Human-readable text

NOT implemented by design: the Flutter/backend layers will localize; the CLI
`--explain` output is the thin deterministic debug formatter.
