# Wellness Engine — HML Shadow Operations (STAGE 19B)

How to operate the HML shadow validation (Phase A historical replay).

## Artifacts

- `wellness-engine/Dockerfile` — multi-stage, CGO_ENABLED=0, distroless
  static non-root, tzdata copied (TZ=America/Sao_Paulo), version injected
  via ldflags (EngineVersion + BuildCommit, never in config_hash).
- `wellness-engine/Makefile` — `make build` (bin/), `make docker-build`,
  `make docker-smoke`.
- `wellness-engine/scripts/container-smoke.sh` — non-root check, /health,
  /ready, B.2 calculate (201, 90/40/78/78), score GET, SIGTERM, binaries.
- `deploy/wellness-engine/{base,overlays/hml}` — Kustomize (noana-k8s
  convention): Deployment wellness-engine-api (replicas 1, ClusterIP,
  probes, bounded resources), one-shot Job wellness-shadow-historical.
- Migration `0002_shadow.up.sql` — `wellness_shadow_comparison` (isolated;
  no raw streams; fingerprint-referenced inputs; idempotent by
  person_hash+logical_day+input_fingerprint).

## Build + local smoke

```
cd wellness-engine
make docker-build            # tag: wellness-engine:dev
./scripts/container-smoke.sh # needs docker + local postgres image
```

## Phase A run (HML)

1. Push the image to the HML ECR (noana-k8s build-and-push convention),
   tag `hml`, and point the overlay image at it.
2. Create secrets in namespace noana-hml (sealed-secrets convention):
   - `wellness-engine-secrets`: DATABASE_URL (HML Postgres), INTERNAL_TOKEN,
     HML_API_BASE (https://api.hml.noana.link/v1), HML_API_TOKEN
   - `wellness-shadow-cohort`: cohort.json — operator-only, NEVER committed:
     `[{"person_hash":"<HMAC pseudonym>","person_uuid":"<backend uuid>",
        "sidecar":{...},"official":{"YYYY-MM-DD":{"sleep":..,"stress":..,
        "readiness":..,"activity":..,"reference":".."}}}]`
3. Apply: `kubectl apply -k deploy/wellness-engine/overlays/hml`
   (or copy the overlay into noana-k8s per its convention).
4. Start SMALL: 2–5 persons × 3–7 consecutive days. Job args FROM_DAY/TO_DAY
   are env-driven; edit the Job (or a patched copy) for the window.

## Interpreting results

- `EXACT` — all four final scores equal (the target for complete inputs).
- `INPUT_INCOMPLETE` — adapter flagged missing inputs (steps
  calories/distance, demographics sidecar). NOT an engine mismatch; the
  Activity score may legitimately differ because the official path uses
  SDK-only calories. Report these separately.
- `MISMATCHED` — real engine parity issue; investigate per case.
- `FAILED` — adapter/engine failure; recorded with failure_code.

Summary query:
`SELECT match_class, count(*) FROM wellness_shadow_comparison GROUP BY 1;`

## Hard gates before any expansion/cutover

- complete-input cases: FINAL/UNKNOWN/GOAL/BASELINE mismatches = 0
- no official side effects (scores/goals/baselines unchanged; no pushes,
  challenges, rankings)
- no PII leakage (person_hash only)
- sleep-stage mapping: PENDING REAL-DEVICE (blocks cutover, not shadow)

## Real HML findings

2026-08-19 Phase A attempt: deployment + migrations executed and verified
(health/ready 200, version hml-a6ab786, 159 → 166 tables, isolation
proven); input fetch BLOCKED on a valid HML backend credential
(noana-secrets COGNITO_PASS stale); official dailyscore is sparse and uses
a strain/physical_capacity model; activity calories/distance/session kcal
UNAVAILABLE in the HML DB (INPUT_INCOMPLETE stays). Details:
`docs/wellness-hml-phase-a-findings.md`.

## Known open items

- steps calories/distance: backend `passos` carries value only; official
  activity kcal uses SDK record calories. If a real day shows an activity
  delta, capture the official breakdown and decide whether the backend can
  store calories (adapter currently flags INPUT_INCOMPLETE — never
  fabricates).
- goal-state sidecar: until the app uploads goal state, the operator
  provides it per person (export from the app).
