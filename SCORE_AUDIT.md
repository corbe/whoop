# SCORE AUDIT — Noana wellness score formulas (Phase 5, spec §1–§2, §76)

Audit date: 2026-08-13. Repos searched: `noana-admin`, `noana-admin2`,
`noana-wellness-app`, `noana-front-app-code`, `noana-curator-server`,
`noana-alert-server`, `noana-eview-server`, `noana-eview-server-gbkp`,
`noana-ws`, `noana-web-front`, `noana-e2e`, `noana-capacity-planning`,
`iot-gateway-thingsboard`, `mqtt`, `app_login`.

Terms searched: `sleep score`, `readiness`, `activity score`, `strain`,
`physical capacity`, `health score`, `user_health_score_total`, `FORMULA_`,
`score formula`, `score calculation`, `score component`, `HRV score`,
`sleep target`, `hrv`, `stress`, `strain_target_pct`.

---

## 1. AUTHORITATIVE FORMULA FOUND — Noana Health Score (clinical)

**Where it runs:** `noana-curator-server/curator/noana_param_processor.py`
(production — Redis Timeseries → per-parameter "within target" scores →
`USER_HEALTH_SCORE_TOTAL`). Functions: `calculate_partial_health_scores`
(L914), `calculate_health_score_using_values_new` (L1180, ACTIVE),
`calculate_health_score_using_values` (L1330, legacy path), `process_health_score`
(L1031).

**Score name:** `USER_HEALTH_SCORE_TOTAL` (+ per-parameter partials
`USER_HEALTH_SCORE_{AWAKE|SLEEP}_{param}_WITHIN_TARGET`).

**Inputs:** raw vitals timeseries (HR, SpO2, steps; + axillary temperature,
SBP/DBP, weight, glucose for "vitals hub") + per-user target/threshold ranges
(`get_user_boundaries`).

**Partial score (per parameter, per interval-of-day):**
```
CI  = [max(acceptable_lo, avg − z·std), min(acceptable_hi, avg + z·std)]
      with z = 1.645 (90% confidence)
subscore_target = 100 · len(CI ∩ [tgt_lo, tgt_hi]) / len(CI)      # 0–100
steps (cumulative): 50 + 50·(vmax−tgt_lo)/(tgt_hi−tgt_lo)          # clamped 0–100
subscore_threshold = −15 if vmax > thres_hi, −15 if vmin < thres_lo
phs = round(subscore_target + subscore_threshold, 1)
```

**Total (active "new" version):**
```
params = [hr, spo2]  (+ [steps] when awake; device-type dependent)
delta_score = round( Σ(1.0 · phsᵢ) / max(3, len(params)), 1 )
USER_HEALTH_SCORE_TOTAL = max(0, min(int(delta_score), 100))
```

**Total (legacy "old" version):** `clamp(last_score + Σ(phsᵢ · 0.011), 60, 100)`;
initial value when no score exists: **80**.

**Range:** 0–100 (both versions clamp). **Normalization:** CI-intersection %
and steps-proportional. **Weights:** fixed_gain 1.0 (new) / 0.011 (old);
per-parameter `hs_weight_1_10` exists but is only used in the disabled
"usage score" path (`include_usage_score_in_final_calculation = 0`).

**Timezone/date behavior:** fixed offset −3 (BRT) via
`unix_time_utc_to_localtime_dict(ts, -3)`; score recomputed per "interval of
day" (morning/afternoon → awake params; evening/night → sleep params).

**Version:** none tracked in code; function name + `_new` suffix is the only
marker. **Production logic:** YES (curator server).

**Reusability for wellness:** the 0–100 range convention and timezone-aware
"wellness day" concept are reusable conventions. The formula itself is a
clinical vitals-within-target score and is NOT a WHOOP-style wellness score;
it also runs server-side on raw timeseries that the wellness app does not
currently ingest. No port attempted in Phase 5.

## 2. LEGACY FIELD — person.health_score (removed)

`noana-admin/backend/person/migrations/0008_person_health_score.py` added a
plain `IntegerField` (2024-07-01); `0010_remove_person_health_score.py`
removed it (2024-08-23). No formula ever shipped. Front apps
(`noana-front-app-code`, `noana-web-front`) merely display the (now removed)
field. Not reusable.

## 3. NOT FOUND — WHOOP-STYLE WELLNESS SCORES (spec §2 STOP CONDITION)

| Score (DailyScore field) | Authoritative formula |
| :--- | :--- |
| `sleep` | **NOT FOUND** |
| `readiness` | **NOT FOUND** (only an l10n string in the clinical app) |
| `stress_trend` / `stress_instant` | **NOT FOUND** |
| `activity` | **NOT FOUND** |
| `strain` / `strain_target_pct` | **NOT FOUND** |
| `physical_capacity` | **NOT FOUND** |

No `FORMULA_*` constants, no score components, no HRV score, no sleep-score
calculation exist in any Noana repository.

**Decision (per spec §2, §76):** production calculation for these scores is
**NOT IMPLEMENTED** in Phase 5. The DailyScore model/API/architecture IS
implemented with nullable fields, and deterministic **test fixtures** (not
formulas) are used for E2E. The 0–100 range validation IS applied because it
is the authoritative Noana score convention (curator server).

**Recommendation:** a formula specification is required before any production
score calculation ships (input data, weights, normalization, timezone rule,
formula_version).
