# wellness-engine HML overlay

Deploy (operator step, requires HML cluster context):

1. Build + push the image to the HML ECR (tag `hml`), following the
   noana-k8s build-and-push convention (image name noana-hml/wellness-engine).
2. Create the secrets in namespace noana-hml (sealed-secrets convention):
   - wellness-engine-secrets: DATABASE_URL (shadow schema on HML Postgres),
     INTERNAL_TOKEN, HML_API_BASE, HML_API_TOKEN
   - wellness-shadow-cohort: cohort.json (person_hash/person_uuid/sidecar/
     official; NEVER committed)
3. kubectl apply -k overlays/hml   (or copy into noana-k8s overlays/hml)

Shadow isolation: the Go shadow writes ONLY wellness_shadow_* tables; the
official path is untouched. Migration 0002 applies on API startup.
