// Integration tests against a REAL Postgres (STAGE 15.15).
//
// DB discovery: TEST_DATABASE_URL env var wins; otherwise a postgres:16-alpine
// container is started via Docker (skipped when Docker is unavailable — the
// constraint/transaction/concurrency guarantees cannot be unit-tested).
package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/persistence"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/repository"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/activity"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/versioning"
)

var testPool *pgxpool.Pool
var containerID string

func TestMain(m *testing.M) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		var err error
		url, containerID, err = startContainer(ctx)
		if err != nil {
			fmt.Fprintln(os.Stderr, "postgres integration tests SKIPPED:", err)
			os.Exit(0) // skip silently-ish; go test reports no tests
		}
	}
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		fmt.Fprintln(os.Stderr, "connect:", err)
		os.Exit(1)
	}
	// wait for readiness
	for i := 0; i < 30; i++ {
		if err := pool.Ping(ctx); err == nil {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if err := pool.Ping(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "postgres not ready:", err)
		os.Exit(1)
	}
	testPool = pool
	code := m.Run()
	testPool.Close()
	if containerID != "" {
		_ = exec.Command("docker", "rm", "-f", containerID).Run()
	}
	os.Exit(code)
}

func startContainer(ctx context.Context) (string, string, error) {
	if _, err := exec.LookPath("docker"); err != nil {
		return "", "", errors.New("docker not found")
	}
	if err := exec.CommandContext(ctx, "docker", "info").Run(); err != nil {
		return "", "", errors.New("docker daemon unavailable")
	}
	port, err := freePort()
	if err != nil {
		return "", "", err
	}
	id, err := exec.CommandContext(ctx, "docker", "run", "-d", "--name", fmt.Sprintf("ritma-wt-%d", time.Now().UnixNano()),
		"-p", fmt.Sprintf("127.0.0.1:%d:5432", port),
		"-e", "POSTGRES_PASSWORD=test", "-e", "POSTGRES_DB=wellness_test",
		"postgres:16-alpine").Output()
	if err != nil {
		return "", "", fmt.Errorf("docker run: %w", err)
	}
	url := fmt.Sprintf("postgres://postgres:test@127.0.0.1:%d/wellness_test?sslmode=disable", port)
	return url, strings.TrimSpace(string(id)), nil
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func newTestStore(t *testing.T) *Store {
	t.Helper()
	ctx := context.Background()
	if err := Migrate(ctx, testPool); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	// hermetic per-test database (disposable container); RESTART IDENTITY so
	// run/goal ids stay deterministic for -count=N runs
	if _, err := testPool.Exec(ctx, `
		TRUNCATE wellness_calculation_run, wellness_daily_score,
		         wellness_goal_state, wellness_baseline_snapshot, wellness_formula_version
		RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	params, _ := json.Marshal(engine.DefaultConfigs())
	s := NewStore(testPool)
	if err := s.SeedFormulaVersions(ctx, params); err != nil {
		t.Fatalf("seed formulas: %v", err)
	}
	// isolated person per test
	return s
}

func testPerson(t *testing.T) string { return "person_" + strings.ReplaceAll(t.Name(), "/", "_") }

func TestMigrateSchema(t *testing.T) {
	ctx := context.Background()
	if err := Migrate(ctx, testPool); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	for _, table := range []string{"wellness_formula_version", "wellness_calculation_run",
		"wellness_daily_score", "wellness_goal_state", "wellness_baseline_snapshot"} {
		var exists bool
		if err := testPool.QueryRow(ctx, `
			SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = $1)`,
			table).Scan(&exists); err != nil {
			t.Fatal(err)
		}
		if !exists {
			t.Errorf("table %s missing after migrate", table)
		}
	}
	// idempotent re-migrate
	if err := Migrate(ctx, testPool); err != nil {
		t.Fatalf("re-migrate must be idempotent: %v", err)
	}
}

func b2Bundle(t *testing.T, person string) (engine.Input, *engine.CalculationBundle) {
	t.Helper()
	in := b2EngineInput(person)
	b, err := engine.CalculateDayDetailed(in, engine.DefaultConfigs())
	if err != nil {
		t.Fatalf("calculate: %v", err)
	}
	return in, b
}

func TestPersistB2AndReadBack(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	in, bundle := b2Bundle(t, testPerson(t))
	rin, rb, err := persistence.ProjectBundle(in, bundle)
	if err != nil {
		t.Fatal(err)
	}
	run, err := s.PersistBundle(ctx, rin, rb)
	if err != nil {
		t.Fatalf("persist: %v", err)
	}
	if run.ReplacesRunID != nil {
		t.Error("first revision must have no replaces_run_id")
	}
	if run.InputFingerprint != rin.Fingerprint {
		t.Errorf("fingerprint mismatch: %s vs %s", run.InputFingerprint, rin.Fingerprint)
	}
	day := rin.Day

	// scores read back EXACTLY (B.2 must not change through persistence)
	want := map[string]int{"sleep": 90, "stress": 40, "readiness": 78, "activity": 78}
	for key, score := range want {
		sc, err := s.CurrentScore(ctx, in.PersonID, day, key)
		if err != nil {
			t.Fatal(err)
		}
		if sc == nil {
			t.Fatalf("%s: no current score", key)
		}
		if sc.Score != score {
			t.Errorf("%s: got %d want %d", key, sc.Score, score)
		}
		if sc.ConfigHash != bundle.Metadata.ConfigHash {
			t.Errorf("%s: config hash mismatch", key)
		}
		// explanation payload round-trips (typed JSONB)
		var ex map[string]any
		if err := json.Unmarshal(sc.Explanation, &ex); err != nil {
			t.Fatalf("%s: explanation is not valid JSON: %v", key, err)
		}
		if ex["score"] != float64(score) {
			t.Errorf("%s: explanation score %v", key, ex["score"])
		}
	}
	// readiness explanation carries components
	sc, _ := s.CurrentScore(ctx, in.PersonID, day, "readiness")
	var ex map[string]any
	_ = json.Unmarshal(sc.Explanation, &ex)
	if comps, ok := ex["components"].([]any); !ok || len(comps) != 5 {
		t.Errorf("readiness explanation must have 5 components, got %v", ex["components"])
	}

	// run revisions + lineage
	runs, err := s.RunRevisions(ctx, in.PersonID, day)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 {
		t.Fatalf("expected 1 run, got %d", len(runs))
	}
	if runs[0].EngineVersion == "" || runs[0].FormulaVersions["sleep"] != 1 {
		t.Errorf("run metadata: %+v", runs[0])
	}
	if !strings.Contains(string(runs[0].QualityJSON), "warnings") {
		t.Error("quality payload missing")
	}

	// formula registry from DB
	v, err := s.ActiveVersion(ctx, versioning.KeySleep)
	if err != nil || v.Version != 1 || v.Status != versioning.StatusActive {
		t.Errorf("ActiveVersion(sleep): %+v err=%v", v, err)
	}
}

func TestIdempotentReplay(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	in, bundle := b2Bundle(t, testPerson(t))
	rin, rb, _ := persistence.ProjectBundle(in, bundle)

	run1, err := s.PersistBundle(ctx, rin, rb)
	if err != nil {
		t.Fatal(err)
	}
	run2, err := s.PersistBundle(ctx, rin, rb)
	if !errors.Is(err, repository.ErrDuplicateRun) {
		t.Fatalf("replay must return ErrDuplicateRun, got %v", err)
	}
	if run1.RunID != run2.RunID {
		t.Errorf("replay must reuse run %d, got %d", run1.RunID, run2.RunID)
	}
	var runCount, scoreCount int
	_ = testPool.QueryRow(ctx, `SELECT count(*) FROM wellness_calculation_run WHERE person_id = $1`, testPerson(t)).Scan(&runCount)
	_ = testPool.QueryRow(ctx, `SELECT count(*) FROM wellness_daily_score WHERE person_id = $1`, testPerson(t)).Scan(&scoreCount)
	if runCount != 1 || scoreCount != 4 {
		t.Errorf("duplicate semantic rows: runs=%d scores=%d (want 1/4)", runCount, scoreCount)
	}
	// current rows still intact
	sc, _ := s.CurrentScore(ctx, in.PersonID, rin.Day, "sleep")
	if sc == nil || sc.Score != 90 {
		t.Errorf("current sleep after replay: %+v", sc)
	}
}

func TestRevisionModel(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)

	// v1
	in, bundle := b2Bundle(t, testPerson(t))
	rin, rb, _ := persistence.ProjectBundle(in, bundle)
	run1, err := s.PersistBundle(ctx, rin, rb)
	if err != nil {
		t.Fatal(err)
	}

	// v2: same day, changed relevant input (different HRV average)
	in2 := b2EngineInput(testPerson(t))
	in2.DailyHrvAverages[10] += 0.5
	b2, err := engine.CalculateDayDetailed(in2, engine.DefaultConfigs())
	if err != nil {
		t.Fatal(err)
	}
	rin2, rb2, _ := persistence.ProjectBundle(in2, b2)
	run2, err := s.PersistBundle(ctx, rin2, rb2)
	if err != nil {
		t.Fatal(err)
	}
	if run2.RunID == run1.RunID {
		t.Fatal("changed input must create a new run")
	}
	if run2.ReplacesRunID == nil || *run2.ReplacesRunID != run1.RunID {
		t.Errorf("v2 must replace v1: %v", run2.ReplacesRunID)
	}

	// v2 current, v1 historical — both readable
	sc, _ := s.CurrentScore(ctx, in.PersonID, rin.Day, "stress")
	if sc == nil || sc.RunID != run2.RunID {
		t.Errorf("current stress must be v2 run %d, got %+v", run2.RunID, sc)
	}
	hist, err := s.ScoreHistory(ctx, in.PersonID, rin.Day, "stress")
	if err != nil {
		t.Fatal(err)
	}
	if len(hist) != 2 {
		t.Fatalf("expected 2 revisions, got %d", len(hist))
	}
	if hist[0].RunID != run2.RunID || hist[1].RunID != run1.RunID {
		t.Errorf("history order: %d,%d want %d,%d", hist[0].RunID, hist[1].RunID, run2.RunID, run1.RunID)
	}
	runs, _ := s.RunRevisions(ctx, in.PersonID, rin.Day)
	if len(runs) != 2 {
		t.Errorf("run revisions: %d", len(runs))
	}
}

func TestConcurrentIdenticalBundles(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	in, bundle := b2Bundle(t, testPerson(t))
	rin, rb, _ := persistence.ProjectBundle(in, bundle)

	const workers = 8
	var wg sync.WaitGroup
	errs := make([]error, workers)
	ids := make([]int64, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			r, err := s.PersistBundle(ctx, rin, rb)
			errs[i] = err
			if r != nil {
				ids[i] = r.RunID
			}
		}(i)
	}
	wg.Wait()
	// exactly one run row, one current score per formula
	var runs, currents int
	_ = testPool.QueryRow(ctx, `SELECT count(*) FROM wellness_calculation_run WHERE person_id = $1`, testPerson(t)).Scan(&runs)
	_ = testPool.QueryRow(ctx, `SELECT count(*) FROM wellness_daily_score WHERE person_id = $1 AND is_current`, testPerson(t)).Scan(&currents)
	if runs != 1 || currents != 4 {
		t.Errorf("concurrent identical: runs=%d currents=%d (want 1/4)", runs, currents)
	}
	first := ids[0]
	for i, id := range ids {
		if id == 0 {
			continue // replay reported no run
		}
		if id != first {
			t.Errorf("worker %d got different run %d", i, id)
		}
	}
	// no partial rows (scores always 4)
	var scores int
	_ = testPool.QueryRow(ctx, `SELECT count(*) FROM wellness_daily_score WHERE person_id = $1`, testPerson(t)).Scan(&scores)
	if scores != 4 {
		t.Errorf("scores=%d want 4", scores)
	}
	_ = errs
}

func TestConcurrentDifferentBundles(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	in, bundle := b2Bundle(t, testPerson(t))
	rin, rb, _ := persistence.ProjectBundle(in, bundle)

	in2 := b2EngineInput(testPerson(t))
	in2.DailyHrvAverages[3] += 1.0
	b2, _ := engine.CalculateDayDetailed(in2, engine.DefaultConfigs())
	rin2, rb2, _ := persistence.ProjectBundle(in2, b2)

	var wg sync.WaitGroup
	var ids [2]int64
	wg.Add(2)
	go func() {
		defer wg.Done()
		r, _ := s.PersistBundle(ctx, rin, rb)
		if r != nil {
			ids[0] = r.RunID
		}
	}()
	go func() {
		defer wg.Done()
		r, _ := s.PersistBundle(ctx, rin2, rb2)
		if r != nil {
			ids[1] = r.RunID
		}
	}()
	wg.Wait()
	if ids[0] == 0 || ids[1] == 0 || ids[0] == ids[1] {
		t.Fatalf("both runs must persist distinctly: %v", ids)
	}
	var currents int
	_ = testPool.QueryRow(ctx, `SELECT count(*) FROM wellness_daily_score WHERE person_id = $1 AND is_current`, testPerson(t)).Scan(&currents)
	if currents != 4 {
		t.Errorf("exactly one current revision per formula expected, got %d current rows", currents)
	}
}

func TestTransactionRollback(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	in, bundle := b2Bundle(t, testPerson(t))
	rin, rb, _ := persistence.ProjectBundle(in, bundle)

	// corrupt one explanation payload → jsonb insert fails mid-transaction
	rb.Scores[0].Explanation = []byte("{not json")
	if _, err := s.PersistBundle(ctx, rin, rb); err == nil {
		t.Fatal("persist with corrupt JSONB must fail")
	}
	var runs int
	_ = testPool.QueryRow(ctx, `SELECT count(*) FROM wellness_calculation_run WHERE person_id = $1`, testPerson(t)).Scan(&runs)
	if runs != 0 {
		t.Errorf("rollback failed: %d run rows persisted", runs)
	}
	var scores int
	_ = testPool.QueryRow(ctx, `SELECT count(*) FROM wellness_daily_score WHERE person_id = $1`, testPerson(t)).Scan(&scores)
	if scores != 0 {
		t.Errorf("rollback failed: %d score rows persisted", scores)
	}
}

func TestGoalStateAndBaseline(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	// goal-enabled bundle (steps goal 7000 → 9000)
	in := b2EngineInput(testPerson(t))
	now := time.Date(2026, 8, 10, 12, 0, 0, 0, time.UTC)
	past := now.Add(-8 * 24 * time.Hour)
	in.GoalStepSamples = repInts(9000, 30)
	in.GoalPriorSteps = 7500
	in.GoalMaxDailySteps = 15000
	in.GoalState = struct {
		CurrentGoal      int
		LastAutoUpdateAt *time.Time
		ManualOverrideAt *time.Time
	}{7000, &past, nil}
	in.Now = now
	bundle, err := engine.CalculateDayDetailed(in, engine.DefaultConfigs())
	if err != nil {
		t.Fatal(err)
	}
	if !bundle.Goals.Steps.Updated {
		t.Fatal("setup: steps goal must update")
	}
	rin, rb, _ := persistence.ProjectBundle(in, bundle)
	if len(rb.GoalChanges) != 1 {
		t.Fatalf("expected 1 goal change, got %d", len(rb.GoalChanges))
	}
	if _, err := s.PersistBundle(ctx, rin, rb); err != nil {
		t.Fatal(err)
	}
	g, err := s.CurrentGoal(ctx, in.PersonID, "goal_steps")
	if err != nil {
		t.Fatal(err)
	}
	if g == nil || g.Value != 9000 || g.Source != "auto" {
		t.Errorf("current goal: %+v", g)
	}
	hist, _ := s.GoalHistory(ctx, in.PersonID, "goal_steps")
	if len(hist) != 1 {
		t.Errorf("goal history: %d", len(hist))
	}
	bs, err := s.CurrentBaseline(ctx, in.PersonID)
	if err != nil {
		t.Fatal(err)
	}
	if bs == nil {
		t.Fatal("baseline snapshot missing")
	}
	var metrics map[string]any
	if err := json.Unmarshal(bs.Metrics, &metrics); err != nil {
		t.Fatal(err)
	}
	if metrics["rhr_baseline_bpm"] == nil {
		t.Error("baseline metrics missing rhr")
	}
	// goal supersede on second revision
	in2 := in
	in2.DailyHrvAverages[0] += 0.25
	b2, _ := engine.CalculateDayDetailed(in2, engine.DefaultConfigs())
	rin2, rb2, _ := persistence.ProjectBundle(in2, b2)
	if _, err := s.PersistBundle(ctx, rin2, rb2); err != nil {
		t.Fatal(err)
	}
	hist2, _ := s.GoalHistory(ctx, in.PersonID, "goal_steps")
	if len(hist2) != 2 {
		t.Errorf("goal history after revision: %d", len(hist2))
	}
}

// b2EngineInput mirrors the B.2 golden day (engine package tests).
func b2EngineInput(person string) engine.Input {
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
	return engine.Input{
		PersonID: person,
		Date:     time.Date(2026, 8, 10, 15, 0, 0, 0, br),
		Location: br,
		Segments: []domain.Segment{
			{StartMs: ms(2026, 8, 9, 23, 26), EndMs: ms(2026, 8, 10, 0, 4), Stage: domain.StageLight},
			{StartMs: ms(2026, 8, 10, 0, 4), EndMs: ms(2026, 8, 10, 0, 42), Stage: domain.StageREM},
			{StartMs: ms(2026, 8, 10, 0, 42), EndMs: ms(2026, 8, 10, 2, 18), Stage: domain.StageDeep},
			{StartMs: ms(2026, 8, 10, 2, 18), EndMs: ms(2026, 8, 10, 7, 26), Stage: domain.StageLight},
		},
		DailyHrvAverages:     daily,
		SleepHistoryScores:   []int{85, 70, 0, 80},
		FatigueHistoryScores: []int{85, 70, 80},
		LastNightRhr:         &rhr,
		RhrBaseline:          &rhrBase,
		Spo2Tonight:          &spo2,
		Spo2Baseline:         &spo2Base,
		StepsRecords: []activity.StepsRecord{
			{Value: 4200, Calories: 168, DistanceM: 3360, Timestamp: ms(2026, 8, 10, 12, 0), Device: domain.DeviceBracelet},
		},
		SessionKcal: 50,
		GoalSteps:   7000,
	}
}

func repInts(v, n int) []int {
	out := make([]int, n)
	for i := range out {
		out[i] = v
	}
	return out
}
