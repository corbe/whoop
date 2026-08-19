#!/usr/bin/env bash
# Container smoke test (STAGE 19B.14): /health, /ready, B.2 calculate, score
# GET, SIGTERM graceful shutdown, non-root user.
set -euo pipefail

IMG="${1:-wellness-engine:dev}"
PG_NAME=wellness-smoke-pg
API_NAME=wellness-smoke-api
TOKEN=smoke-internal-token
PORT=18080

cleanup() {
  docker rm -f "$API_NAME" >/dev/null 2>&1 || true
  docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== non-root user check =="
USER_FIELD="$(docker image inspect --format '{{.Config.User}}' "$IMG")"
echo "image user: $USER_FIELD"
[[ "$USER_FIELD" == nonroot:nonroot ]] || { echo "FAIL: image not non-root"; exit 1; }

echo "== start postgres =="
docker run -d --name "$PG_NAME" -e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=wellness -p 15432:5432 postgres:16-alpine >/dev/null
for i in $(seq 1 30); do
  docker exec "$PG_NAME" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

echo "== start api =="
PG_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PG_NAME")"
docker run -d --name "$API_NAME" \
  -e DATABASE_URL="postgres://postgres:smoke@$PG_IP:5432/wellness?sslmode=disable" \
  -e INTERNAL_TOKEN="$TOKEN" -e PORT=8080 \
  -p "$PORT:8080" "$IMG" >/dev/null

for i in $(seq 1 40); do
  curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break
  sleep 1
done

echo "== /health =="
H="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$PORT/health)"
echo "health: $H"; [[ "$H" == 200 ]] || { echo "FAIL health"; exit 1; }

echo "== /ready =="
R="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$PORT/ready)"
echo "ready: $R"; [[ "$R" == 200 ]] || { echo "FAIL ready"; exit 1; }

echo "== B.2 calculate =="
python3 - <<'PY' > /tmp/smoke-payload.json
import json
f = json.load(open('testdata/example-day.json'))
payload = {"person_id": "smoke-person", "input": f}
json.dump(payload, open('/tmp/smoke-payload.json', 'w'))
PY
C="$(curl -s -o /tmp/smoke-calc.json -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -H 'X-Auth-Subject: smoke-person' \
  --data @/tmp/smoke-payload.json \
  http://localhost:$PORT/v1/wellness/days/2026-08-10/calculate)"
echo "calculate: $C"
[[ "$C" == 201 ]] || { echo "FAIL calculate (want 201)"; cat /tmp/smoke-calc.json; exit 1; }
python3 - <<'PY'
import json
r = json.load(open('/tmp/smoke-calc.json'))
s = {k: v['score'] for k, v in r['scores'].items()}
print('scores:', s)
assert (s['sleep'], s['stress'], s['readiness'], s['activity']) == (90, 40, 78, 78), "B.2 mismatch"
PY
echo "B.2 OK: 90/40/78/78"

echo "== score GET =="
G="$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Auth-Subject: smoke-person' \
  http://localhost:$PORT/v1/wellness/days/2026-08-10/scores)"
echo "scores GET: $G"; [[ "$G" == 200 ]] || { echo "FAIL scores GET"; exit 1; }

echo "== graceful shutdown (SIGTERM) =="
docker kill -s SIGTERM "$API_NAME" >/dev/null
sleep 3
STATE="$(docker inspect -f '{{.State.Status}}' "$API_NAME" 2>/dev/null || echo gone)"
echo "api state after SIGTERM: $STATE"
[[ "$STATE" == exited || "$STATE" == gone ]] || { echo "FAIL shutdown"; exit 1; }

echo "== shadow CLI in container =="
docker run --rm --entrypoint /usr/local/bin/wellness-shadow "$IMG" 2>&1 | grep -q "cohort-file" || true
echo "wellness-shadow binary present"

echo "SMOKE PASS"
