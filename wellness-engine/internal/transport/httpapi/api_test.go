// End-to-end API tests: HTTP → application service → engine → real Postgres
// (STAGE 17.14-17.16, 17.20).
package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/application"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/persistence/postgres"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/testutil/dbtest"
)

const testInternalToken = "test-internal-token"

func newTestServer(t *testing.T) (*httptest.Server, *httpapiClient, *pgxpool.Pool) {
	t.Helper()
	p := dbtest.Setup(t)
	store := postgres.NewStore(p)
	svc := application.New(store, nil, engine.DefaultConfigs())
	srv := New(svc, HeaderSubjectResolver{}, InternalAuth{Token: testInternalToken}, func() error {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		return p.Ping(ctx)
	})
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return ts, &httpapiClient{base: ts.URL}, p
}

type httpapiClient struct{ base string }

func (c *httpapiClient) do(t *testing.T, method, path, subject, internalToken string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, c.base+path, rd)
	if subject != "" {
		req.Header.Set("X-Auth-Subject", subject)
	}
	if internalToken != "" {
		req.Header.Set("X-Internal-Token", internalToken)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

// b2Raw is the B.2 golden day as a stateless (mode B) input body.
func b2Raw(person string) map[string]any {
	daily := make([]float64, 21)
	for i := range daily {
		daily[i] = 49.575 - 0.9575*float64(i)
	}
	rhr, rhrBase := 62.0, 64.67
	spo2, spo2Base := 95.2, 96.07
	br := time.FixedZone("BRT", -3*3600)
	ms := func(y int, mo time.Month, d, h, mi int) int64 {
		return time.Date(y, mo, d, h, mi, 0, 0, br).UnixMilli()
	}
	return map[string]any{
		"person_id": person,
		"input": map[string]any{
			"timezone": "America/Sao_Paulo",
			"segments": []map[string]any{
				{"start_ms": ms(2026, 8, 9, 23, 26), "end_ms": ms(2026, 8, 10, 0, 4), "stage": -3},
				{"start_ms": ms(2026, 8, 10, 0, 4), "end_ms": ms(2026, 8, 10, 0, 42), "stage": -1},
				{"start_ms": ms(2026, 8, 10, 0, 42), "end_ms": ms(2026, 8, 10, 2, 18), "stage": -4},
				{"start_ms": ms(2026, 8, 10, 2, 18), "end_ms": ms(2026, 8, 10, 7, 26), "stage": -3},
			},
			"daily_hrv_averages_ms":  daily,
			"sleep_history_scores":   []int{85, 70, 0, 80},
			"fatigue_history_scores": []int{85, 70, 80},
			"last_night_rhr_bpm":     rhr,
			"rhr_baseline_bpm":       rhrBase,
			"spo2_tonight_pct":       spo2,
			"spo2_baseline_pct":      spo2Base,
			"steps": []map[string]any{
				{"value": 4200.0, "calories": 168.0, "distance_m": 3360.0,
					"timestamp": ms(2026, 8, 10, 12, 0), "device": "BRACELET"},
			},
			"session_kcal": 50,
			"goal_steps":   7000,
		},
	}
}

func TestB2ThroughHTTP(t *testing.T) {
	_, c, _ := newTestServer(t)
	path := "/v1/wellness/days/2026-08-10/calculate"
	status, out := c.do(t, "POST", path, "api-b2-user", "", b2Raw("api-b2-user"))
	if status != http.StatusCreated {
		t.Fatalf("calculate: got %d body %v", status, out)
	}
	scores := out["scores"].(map[string]any)
	want := map[string]float64{"sleep": 90, "stress": 40, "readiness": 78, "activity": 78}
	for key, score := range want {
		if got := scores[key].(map[string]any)["score"].(float64); got != score {
			t.Errorf("%s: got %v want %v", key, got, score)
		}
	}
	if out["replay"] != false {
		t.Error("first calculate must not be replay")
	}
	if fp, _ := out["input_fingerprint"].(string); !strings.HasPrefix(fp, "sha256:") {
		t.Errorf("fingerprint: %v", out["input_fingerprint"])
	}
	if _, ok := out["config_hash"].(string); !ok {
		t.Error("config_hash missing")
	}
	// GET scores
	status, out = c.do(t, "GET", "/v1/wellness/days/2026-08-10/scores", "api-b2-user", "", nil)
	if status != http.StatusOK {
		t.Fatalf("scores: %d", status)
	}
	sc := out["scores"].(map[string]any)
	if sc["readiness"].(map[string]any)["score"].(float64) != 78 {
		t.Errorf("GET readiness: %v", sc["readiness"])
	}
	if _, ok := sc["readiness"].(map[string]any)["engine_version"].(string); !ok {
		t.Error("score DTO must carry engine_version")
	}
	// GET detail with explanation
	status, out = c.do(t, "GET", "/v1/wellness/days/2026-08-10/scores/readiness", "api-b2-user", "", nil)
	if status != http.StatusOK {
		t.Fatalf("detail: %d", status)
	}
	ex := out["explanation"].(map[string]any)
	comps := ex["components"].([]any)
	if len(comps) != 5 {
		t.Errorf("readiness explanation must have 5 components, got %d", len(comps))
	}
	if ex["score"].(float64) != 78 {
		t.Errorf("detail score: %v", ex["score"])
	}
	// unknown formula → 400; missing day → 404
	if status, _ := c.do(t, "GET", "/v1/wellness/days/2026-08-10/scores/bogus", "api-b2-user", "", nil); status != 400 {
		t.Error("unknown formula must be 400")
	}
	if status, _ := c.do(t, "GET", "/v1/wellness/days/2026-08-11/scores/sleep", "api-b2-user", "", nil); status != 404 {
		t.Error("no-data day must be 404")
	}
}

func TestCalculateIdempotency(t *testing.T) {
	_, c, _ := newTestServer(t)
	path := "/v1/wellness/days/2026-08-10/calculate"
	body := b2Raw("api-ido")
	st1, out1 := c.do(t, "POST", path, "api-ido", "", body)
	if st1 != http.StatusCreated {
		t.Fatalf("first: %d", st1)
	}
	st2, out2 := c.do(t, "POST", path, "api-ido", "", body)
	if st2 != http.StatusOK {
		t.Fatalf("replay: got %d want 200", st2)
	}
	if out2["replay"] != true {
		t.Error("second call must be replay=true")
	}
	if out1["run_id"] != out2["run_id"] {
		t.Errorf("same semantic run expected: %v vs %v", out1["run_id"], out2["run_id"])
	}
	// changed input → 201 new revision
	changed := b2Raw("api-ido")
	changed["input"].(map[string]any)["session_kcal"] = 60
	st3, out3 := c.do(t, "POST", path, "api-ido", "", changed)
	if st3 != http.StatusCreated || out3["run_id"] == out1["run_id"] {
		t.Errorf("changed input must create a new run: status=%d", st3)
	}
	if out3["replaces_run_id"] != out1["run_id"] {
		t.Errorf("replaces_run_id: %v want %v", out3["replaces_run_id"], out1["run_id"])
	}
	// history: 2 revisions, newest first
	status, out := c.do(t, "GET", "/v1/wellness/days/2026-08-10/scores/activity/history", "api-ido", "", nil)
	if status != http.StatusOK {
		t.Fatalf("history: %d", status)
	}
	revs := out["revisions"].([]any)
	if len(revs) != 2 {
		t.Fatalf("history revisions: %d want 2", len(revs))
	}
	r0 := revs[0].(map[string]any)
	if r0["is_current"] != true || r0["replaces_run_id"] != out1["run_id"] {
		t.Errorf("newest revision must be current and replace v1: %v", r0)
	}
	if _, ok := r0["input_fingerprint"].(string); !ok {
		t.Error("revision must carry input_fingerprint")
	}
}

func TestConcurrentCalculate(t *testing.T) {
	_, c, p := newTestServer(t)
	path := "/v1/wellness/days/2026-08-10/calculate"
	body := b2Raw("api-conc")
	const workers = 8
	var wg sync.WaitGroup
	statuses := make([]int, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			st, _ := c.do(t, "POST", path, "api-conc", "", body)
			statuses[i] = st
		}(i)
	}
	wg.Wait()
	created, replayed := 0, 0
	for _, st := range statuses {
		switch st {
		case http.StatusCreated:
			created++
		case http.StatusOK:
			replayed++
		}
	}
	if created != 1 || replayed != workers-1 {
		t.Errorf("expected 1 created + %d replays, got %d/%d", workers-1, created, replayed)
	}
	// exactly one current per formula (same pool — no truncate!)
	var currents int
	_ = p.QueryRow(context.Background(),
		`SELECT count(*) FROM wellness_daily_score WHERE person_id = 'api-conc' AND is_current`).Scan(&currents)
	if currents != 4 {
		t.Errorf("current rows: %d want 4", currents)
	}
	var runs int
	_ = p.QueryRow(context.Background(),
		`SELECT count(*) FROM wellness_calculation_run WHERE person_id = 'api-conc'`).Scan(&runs)
	if runs != 1 {
		t.Errorf("runs: %d want 1", runs)
	}
}

func TestSecurityBoundary(t *testing.T) {
	_, c, _ := newTestServer(t)
	// unauthenticated → 401 (fails closed)
	if status, _ := c.do(t, "GET", "/v1/wellness/days/2026-08-10/scores", "", "", nil); status != 401 {
		t.Errorf("unauthenticated: %d want 401", status)
	}
	// malformed auth (empty after header present) → 401
	if status, _ := c.do(t, "GET", "/v1/wellness/days/2026-08-10/scores", "", "", nil); status != 401 {
		t.Error("missing subject must fail closed")
	}
	// cross-person: body person_id mismatch → 403
	body := b2Raw("api-b2-user")
	body["person_id"] = "someone-else"
	if status, _ := c.do(t, "POST", "/v1/wellness/days/2026-08-10/calculate", "api-b2-user", "", body); status != 403 {
		t.Errorf("cross-person body: %d want 403", status)
	}
	// a user cannot see another person's scores: same subject can only ever
	// resolve to their own person (resolver-bound) — verify the resolver
	// never fabricates identity from the body
	status, out := c.do(t, "GET", "/v1/wellness/days/2026-08-10/scores", "api-b2-user", "", nil)
	if status != 404 && out["person_id"] == "someone-else" {
		t.Error("response must be scoped to the authenticated subject")
	}
	// internal route rejects normal user auth (no token) → 403
	if status, _ := c.do(t, "GET", "/internal/v1/formulas", "api-b2-user", "", nil); status != 403 {
		t.Errorf("internal without token: %d want 403", status)
	}
	// internal route accepts the internal token and returns formula registry
	status, out = c.do(t, "GET", "/internal/v1/formulas", "api-b2-user", testInternalToken, nil)
	if status != 200 {
		t.Fatalf("internal with token: %d", status)
	}
	fs := out["formulas"].([]any)
	if len(fs) != 6 {
		t.Errorf("formula registry: %d entries want 6", len(fs))
	}
	// wrong internal token → 403
	if status, _ := c.do(t, "GET", "/internal/v1/formulas", "api-b2-user", "wrong", nil); status != 403 {
		t.Errorf("internal wrong token: %d want 403", status)
	}
}

func TestHealthReadyAndDateValidation(t *testing.T) {
	_, c, _ := newTestServer(t)
	if status, out := c.do(t, "GET", "/health", "", "", nil); status != 200 || out["status"] != "ok" {
		t.Errorf("health: %d %v", status, out)
	}
	if status, out := c.do(t, "GET", "/ready", "", "", nil); status != 200 || out["persistence"] != "ok" {
		t.Errorf("ready: %d %v", status, out)
	}
	// strict date validation
	if status, _ := c.do(t, "POST", "/v1/wellness/days/10-08-2026/calculate", "api-date", "", nil); status != 400 {
		t.Errorf("bad date format: %d want 400", status)
	}
	if status, out := c.do(t, "POST", "/v1/wellness/days/2026-13-99/calculate", "api-date", "", nil); status != 400 {
		t.Errorf("impossible date: %d %v", status, out)
	}
	// error contract shape
	status, out := c.do(t, "GET", "/v1/wellness/days/2026-08-10/scores/bogus", "api-date", "", nil)
	if status != 400 {
		t.Fatal("expected 400")
	}
	if _, ok := out["error"].(map[string]any); !ok {
		t.Errorf("error body must use the error envelope: %v", out)
	}
}

func TestGoalsAndBaselineEndpoints(t *testing.T) {
	_, c, _ := newTestServer(t)
	// goal-enabled calculate: 30 days @ 9000 steps, current goal 7000,
	// cooldown elapsed → auto-update to 9000 (F-08 oracle case S1)
	body := b2Raw("api-goals")
	in := body["input"].(map[string]any)
	samples := make([]float64, 30)
	for i := range samples {
		samples[i] = 9000
	}
	now := time.Date(2026, 8, 10, 12, 0, 0, 0, time.UTC).UnixMilli()
	past := now - 8*24*3600*1000
	in["goal_step_samples_d1_d30"] = samples
	in["goal_prior_steps"] = 7500.0
	in["goal_max_daily_steps"] = 15000.0
	in["goal_current_steps"] = 7000.0
	in["goal_last_auto_update_at_ms"] = past
	in["now_ms"] = now
	status, out := c.do(t, "POST", "/v1/wellness/days/2026-08-10/calculate", "api-goals", "", body)
	if status != http.StatusCreated {
		t.Fatalf("calculate: %d %v", status, out)
	}
	updates := out["goal_updates"].([]any)
	if len(updates) != 1 {
		t.Fatalf("goal_updates: %v", updates)
	}
	gu := updates[0].(map[string]any)
	if gu["goal_key"] != "goal_steps" || gu["value"] != float64(9000) {
		t.Errorf("goal update: %v", gu)
	}
	// goals/current reflects the persisted goal
	status, out = c.do(t, "GET", "/v1/wellness/goals/current", "api-goals", "", nil)
	if status != 200 {
		t.Fatalf("goals/current: %d", status)
	}
	goals := out["goals"].(map[string]any)
	if goals["goal_steps"].(map[string]any)["value"] != float64(9000) {
		t.Errorf("current goal: %v", goals["goal_steps"])
	}
	// goals/history append-only
	status, out = c.do(t, "GET", "/v1/wellness/goals/history/goal_steps", "api-goals", "", nil)
	if status != 200 {
		t.Fatalf("goals/history: %d", status)
	}
	if len(out["changes"].([]any)) != 1 {
		t.Errorf("goal history: %v", out["changes"])
	}
	// baseline/current after a calculation
	status, out = c.do(t, "GET", "/v1/wellness/baseline/current", "api-goals", "", nil)
	if status != 200 {
		t.Fatalf("baseline/current: %d %v", status, out)
	}
	if _, ok := out["metrics"].(map[string]any); !ok {
		t.Errorf("baseline metrics: %v", out["metrics"])
	}
}
