# Wellness Engine — Real HML Phase A Findings (STAGE 19B)

Operational record of the first real-HML shadow validation attempt
(2026-08-19). No PII, no UUIDs, no secrets.

## Deployment (executed)

- Image built from `noana-wellness-app@a6ab786`, pushed to
  `525534623487.dkr.ecr.us-east-1.amazonaws.com/noana-wellness-engine:hml-a6ab786`
  (digest `sha256:dcb2eef7...`; second push after fixing the migrated
  Dockerfile `-X` ldflags path — the first deploy reported `dev` because
  `imagePullPolicy: IfNotPresent` reused a stale same-tag cache; fixed with
  `Always` + restart. Version metadata does NOT affect formula_version /
  config_hash / input_fingerprint by construction).
- Namespace `noana-hml`, Deployment `wellness-engine-api`: replicas 1,
  ClusterIP (no ingress), non-root distroless, probes /health + /ready,
  resources 50m/64Mi requests, 250m/256Mi limits.
- Pod Running, restarts 0. `/health` = 200
  (`{"status":"ok","engine_version":"hml-a6ab786"}`), `/ready` = 200.

## Migrations + side-effect isolation (verified)

- HML Postgres (`rds.hml.noana.internal`, `postgres` DB — the shared HML
  instance, no new RDS per 19B.18): 159 official tables BEFORE →
  166 AFTER. Exactly +7: `wellness_formula_version`,
  `wellness_calculation_run`, `wellness_daily_score`, `wellness_goal_state`,
  `wellness_baseline_snapshot`, `wellness_shadow_comparison`,
  `schema_migrations` (0001 + 0002). No official table modified.
- Name-collision check: the backend's OWN tables use distinct names
  (`wellness_dailyscore` vs engine `wellness_daily_score`; `wellness_wellnessperson`,
  `wellness_gamificationprofile`, `wellness_wellnessstreak`, ...) — no
  conflicts, engine tables are prefix-safe.

## Cohort + official reference availability (real evidence)

- 6 wellness persons exist; 16 official `wellness_dailyscore` rows. Data is
  SPARSE: most rows carry readiness only; complete rows (sleep+readiness+
  activity+strain) exist for exactly 2 person-days (2026-08-13, persons 1–2).
- Official model differs from the engine: `sleep`, `readiness`, `activity`,
  `strain`, `strain_target_pct`, `physical_capacity`, `stress_trend`,
  `stress_instant`, `formula_version`, `computed_by`, `source_device_id`.
  The official "stress" is split across `stress_trend`/`stress_instant`;
  the engine's stress score must be mapped to the official stress field
  before comparison (candidate: `stress_trend`).
- Per the no-invention rule, the comparable cohort = complete official days
  only; sparse days are recorded as missing-reference, not fabricated.

## Input fetch — OPERATOR BLOCKER

- The backend timeseries endpoints require Cognito JWT
  (`django_cognito_jwt.JSONWebTokenAuthentication`). The HML Cognito
  credential in `noana-secrets` (COGNITO_USER/COGNITO_PASS, pool
  `us-east-1_BFGyiLUlb`, client `6dj5pdv3fnrg8jbknu12ljg30k`) fails
  USER_PASSWORD_AUTH (`NotAuthorizedException: Incorrect username or
  password`) — stale or wrong-user. No valid app token could be minted from
  this environment.
- Required (name only): a valid HML backend API credential for
  `HML_API_TOKEN` (wellness-engine-secrets placeholder `OPERATOR_REQUIRED`).
- Everything else is staged: `wellness-shadow-historical` Job manifest,
  cohort file structure, secrets skeleton, runbook.

## Activity input investigation (real evidence)

Classified per the 19B.13 categories:

| input | classification | evidence |
|---|---|---|
| steps value | BACKEND_AVAILABLE | `passos` timeseries (value only) |
| steps calories | UNAVAILABLE | no column matching %calor% in the HML DB; payload value-only |
| distance | UNAVAILABLE | no column matching %distance% (only WAL/planning stats) |
| session kcal | UNAVAILABLE | no activity-session/kcal table in the HML DB |
| official activity score | BACKEND_AVAILABLE (reference only) | `wellness_dailyscore.activity` (sparse) |

Conclusion: activity totalKcal inputs are UNAVAILABLE backend-side;
`INPUT_INCOMPLETE` remains the correct classification for activity until the
app uploads session kcal/calories or the backend stores them. The official
activity reference VALUE exists (sparse) and can seed the comparison.

## Sleep mapping — PENDING

No SDK-labeled (`BRACELET`) stage records are recoverable from the backend;
the real-device verification procedure requires app-side device data.
PENDING — BLOCKS CUTOVER (not shadow).

## Performance (observational baseline)

- API idle: ~1m CPU / ~2Mi memory (kubectl top, 1 replica). No cohort
  calculations ran (input fetch blocked), so calculation latency and Job
  throughput remain unmeasured — recorded as pending operator steps.

## Side-effect proof

- Before: 159 official tables. After deployment + migrations: 166 (only
  engine tables). Official scores/goals/baselines/challenges/rankings/
  pushes untouched (no shadow calculation executed; the Job has never run).

## Operator next steps

1. Provide a valid HML backend credential (refresh COGNITO_PASS or a
   service token) → set `wellness-engine-secrets.HML_API_TOKEN`.
2. Build the local cohort file (person UUIDs → HMAC person_hash; official
   values from `wellness_dailyscore` complete rows only), create
   `wellness-shadow-cohort` secret, set Job FROM_DAY/TO_DAY, run the Job.
3. Measure real input-fetch + calculation latency and record Job results.
4. Resolve the official stress field mapping (stress_trend) with the app
   team before interpreting stress comparisons.
