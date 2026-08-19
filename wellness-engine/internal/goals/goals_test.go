package goals

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/baseline"
)

// loadGoalsOracle reads docs/golden/oracle-goals.json (produced by the REAL
// Dart implementation — test/goal_oracle_test.dart with in-memory Isar +
// mocked SharedPreferences).
func loadGoalsOracle(t *testing.T) map[string]any {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve path")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	raw, err := os.ReadFile(filepath.Join(root, "docs", "golden", "oracle-goals.json"))
	if err != nil {
		t.Fatalf("read oracle-goals.json: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parse oracle-goals.json: %v", err)
	}
	return m
}

func fnum(t *testing.T, m map[string]any, key string) float64 {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("field %q missing", key)
	}
	switch n := v.(type) {
	case float64:
		return n
	case nil:
		return 0
	}
	t.Fatalf("field %q not numeric: %T", key, v)
	return 0
}

func str(t *testing.T, m map[string]any, key string) string {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("field %q missing", key)
	}
	s, _ := v.(string)
	return s
}

func bval(t *testing.T, m map[string]any, key string) bool {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("field %q missing", key)
	}
	b, _ := v.(bool)
	return b
}

// now/past model the oracle's wall-clock: cooldown (7d) elapsed = past
// (now−8d); manual override active = now−1h.
var (
	oracleNow      = time.Date(2026, 8, 10, 12, 0, 0, 0, time.UTC)
	oraclePast     = oracleNow.Add(-8 * 24 * time.Hour)
	oracleOverride = oracleNow.Add(-1 * time.Hour)
)

func TestGoldenStepsOracle(t *testing.T) {
	oracle := loadGoalsOracle(t)
	cfg := DefaultConfig()

	type oracleBlob struct {
		stepsBaseline map[string]any
		update        map[string]any
		persisted     *float64
	}
	get := func(name string) oracleBlob {
		t.Helper()
		v := oracle[name].(map[string]any)
		blob := v
		if b, ok := v["output"]; ok {
			blob = b.(map[string]any)
		} else {
			blob = v["first"].(map[string]any) // repeated case
		}
		var persisted *float64
		if p, ok := blob["persistedGoalSteps"].(float64); ok {
			persisted = &p
		}
		return oracleBlob{
			stepsBaseline: blob["stepsBaseline"].(map[string]any),
			update:        blob["update"].(map[string]any),
			persisted:     persisted,
		}
	}

	cases := []struct {
		name     string
		samples  []int
		current  int
		override bool
		cooldown bool // false → last update 1h ago (cooldown active)
	}{
		{"goal_s1_increase", rep(9000, 30), 7000, false, true},
		{"goal_s2_decrease", rep(4000, 30), 7000, false, true},
		{"goal_s3_unchanged", rep(7000, 30), 7000, false, true},
		{"goal_s4_cap_boundary", rep(9455, 30), 7000, false, true},
		{"goal_s4b_cap_nontrigger", rep(9450, 30), 7000, false, true},
		{"goal_s5_insufficient", rep(8000, 10), 7000, false, true},
		{"goal_s6_missing_days", rep(8000, 14), 7000, false, true},
		{"goal_s7_extreme_high", rep(20000, 30), 7000, false, true},
		{"goal_s8_extreme_low", rep(100, 30), 7000, false, true},
		{"goal_s9_new_user", nil, 0, false, true},
		{"goal_s10_manual_override", rep(9000, 30), 7000, true, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			want := get(c.name)
			state := StepsState{CurrentGoal: c.current}
			if c.cooldown {
				state.LastAutoUpdateAt = &oraclePast
			} else {
				at := oracleNow.Add(-1 * time.Hour)
				state.LastAutoUpdateAt = &at
			}
			if c.override {
				state.ManualOverrideAt = &oracleOverride
			}
			got := UpdateSteps(StepsInput{
				DailySamples:  c.samples,
				Prior:         7500, // demographics M/36y → prior 7500
				MaxDailySteps: 15000,
				State:         state,
				Now:           oracleNow,
				Cfg:           cfg,
			})

			// baseline value / observed / sampleCount / confidence
			wantVal := fnum(t, want.stepsBaseline, "value")
			wantCount := int(fnum(t, want.stepsBaseline, "sampleCount"))
			wantConf := str(t, want.stepsBaseline, "confidence")
			if math.Abs(got.Baseline.Value-wantVal) > 1e-9 {
				t.Errorf("baseline value: got %v want %v", got.Baseline.Value, wantVal)
			}
			if got.Baseline.SampleCount != wantCount {
				t.Errorf("sampleCount: got %d want %d", got.Baseline.SampleCount, wantCount)
			}
			if got.Baseline.Confidence.String() != wantConf {
				t.Errorf("confidence: got %s want %s", got.Baseline.Confidence, wantConf)
			}

			// update
			wantUpd := bval(t, want.update, "stepsUpdated")
			if got.Updated != wantUpd {
				t.Errorf("updated: got %v want %v", got.Updated, wantUpd)
			}
			if wantNew, ok := want.update["newStepsGoal"].(float64); ok {
				if got.NewGoal == nil || *got.NewGoal != int(wantNew) {
					t.Errorf("newGoal: got %v want %v", got.NewGoal, wantNew)
				}
			} else if got.NewGoal != nil {
				t.Errorf("newGoal: got %v want nil", *got.NewGoal)
			}
			// persisted goal
			if want.persisted != nil {
				if got.EffectiveGoal != int(*want.persisted) {
					t.Errorf("effective/persisted goal: got %d want %v", got.EffectiveGoal, *want.persisted)
				}
			}
		})
	}

	// S11 repeated update: first applies, second blocked by cooldown
	t.Run("goal_s11_repeated", func(t *testing.T) {
		v := oracle["goal_s11_repeated"].(map[string]any)
		first := v["first"].(map[string]any)
		second := v["second"].(map[string]any)
		state := StepsState{CurrentGoal: 7000, LastAutoUpdateAt: &oraclePast}
		r1 := UpdateSteps(StepsInput{DailySamples: rep(9000, 30), Prior: 7500,
			MaxDailySteps: 15000, State: state, Now: oracleNow, Cfg: cfg})
		if !r1.Updated || r1.NewGoal == nil || *r1.NewGoal != 9000 {
			t.Errorf("first run: got updated=%v new=%v want true/9000", r1.Updated, r1.NewGoal)
		}
		_ = first
		// second run: cooldown active (last update just happened)
		state2 := StepsState{CurrentGoal: 9000, LastAutoUpdateAt: &oracleNow}
		r2 := UpdateSteps(StepsInput{DailySamples: rep(9000, 30), Prior: 7500,
			MaxDailySteps: 15000, State: state2, Now: oracleNow, Cfg: cfg})
		if r2.Updated {
			t.Error("second run must be blocked by cooldown")
		}
		upd2 := second["update"].(map[string]any)
		if bval(t, upd2, "stepsUpdated") {
			t.Error("oracle says second run must not update")
		}
	})
}

func TestGoldenSleepOracle(t *testing.T) {
	oracle := loadGoalsOracle(t)
	cfg := DefaultConfig()

	cases := []struct {
		name      string
		bedtime   []int // normalized minutes
		duration  []int // minutes
		curBed    int
		curTarget int
		override  bool
	}{
		{"goal_t1_bedtime_shift", rep(1410, 21), rep(480, 21), 1320, 480, false},
		{"goal_t2_target_decrease", rep(1380, 21), rep(360, 21), 1320, 480, false},
		{"goal_t3_sleep_unchanged", rep(1320, 21), rep(480, 21), 1320, 480, false},
		{"goal_t4_sleep_manual_override", rep(1410, 21), rep(480, 21), 1320, 480, true},
		{"goal_t5_sleep_insufficient", rep(1410, 10), rep(480, 10), 1320, 480, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			v := oracle[c.name].(map[string]any)
			blob := v["output"].(map[string]any)
			wantBase := blob["sleepBaselines"].(map[string]any)
			wantUpd := blob["update"].(map[string]any)

			state := SleepState{}
			curBed, curTarget := c.curBed, c.curTarget
			state.CurrentBedTime = &curBed
			state.CurrentSleepTarget = &curTarget
			state.LastAutoUpdateAt = &oraclePast
			if c.override {
				state.ManualOverrideAt = &oracleOverride
			}
			got := UpdateSleep(SleepInput{
				BedtimeMinutes:   c.bedtime,
				DurationMinutes:  c.duration,
				PriorBedTime:     1320,
				PriorSleepTarget: 480,
				State:            state,
				Now:              oracleNow,
				Cfg:              cfg,
			})

			// baseline outputs
			if got.BedTimeMinutes != int(fnum(t, wantBase, "bedTimeMinutes")) {
				t.Errorf("baseline bed: got %d want %v", got.BedTimeMinutes, fnum(t, wantBase, "bedTimeMinutes"))
			}
			if got.SleepTargetMinutes != int(fnum(t, wantBase, "sleepTargetMinutes")) {
				t.Errorf("baseline target: got %d want %v", got.SleepTargetMinutes, fnum(t, wantBase, "sleepTargetMinutes"))
			}
			if got.SampleCount != int(fnum(t, wantBase, "sampleCount")) {
				t.Errorf("sampleCount: got %d want %v", got.SampleCount, fnum(t, wantBase, "sampleCount"))
			}
			if got.Confidence.String() != str(t, wantBase, "confidence") {
				t.Errorf("confidence: got %s want %s", got.Confidence, str(t, wantBase, "confidence"))
			}
			wantStd := fnum(t, wantBase, "bedtimeStdDevMinutes")
			if math.Abs(got.BedtimeStdDevMinutes-wantStd) > 1e-9 {
				t.Errorf("stddev: got %v want %v", got.BedtimeStdDevMinutes, wantStd)
			}

			// update
			wantUpdFlag := bval(t, wantUpd, "sleepUpdated")
			if got.Updated != wantUpdFlag {
				t.Errorf("updated: got %v want %v", got.Updated, wantUpdFlag)
			}
			if wantBed, ok := wantUpd["newBedTimeMinutes"].(float64); ok {
				if got.NewBedTime == nil || *got.NewBedTime != int(wantBed) {
					t.Errorf("newBed: got %v want %v", got.NewBedTime, wantBed)
				}
			} else if got.NewBedTime != nil {
				t.Errorf("newBed: got %v want nil", *got.NewBedTime)
			}
			if wantTarget, ok := wantUpd["newSleepTargetMinutes"].(float64); ok {
				if got.NewSleepTarget == nil || *got.NewSleepTarget != int(wantTarget) {
					t.Errorf("newTarget: got %v want %v", got.NewSleepTarget, wantTarget)
				}
			} else if got.NewSleepTarget != nil {
				t.Errorf("newTarget: got %v want nil", *got.NewSleepTarget)
			}
		})
	}
}

func TestGoalIdempotentSameInput(t *testing.T) {
	cfg := DefaultConfig()
	state := StepsState{CurrentGoal: 7000, LastAutoUpdateAt: &oraclePast}
	in := StepsInput{DailySamples: rep(9000, 30), Prior: 7500, MaxDailySteps: 15000,
		State: state, Now: oracleNow, Cfg: cfg}
	r1 := UpdateSteps(in)
	r2 := UpdateSteps(in)
	if r1.Updated != r2.Updated || (r1.NewGoal != nil && r2.NewGoal != nil && *r1.NewGoal != *r2.NewGoal) {
		t.Errorf("same input must produce identical results: %+v vs %+v", r1, r2)
	}
	// effective goal = new goal
	if r1.Updated && r1.EffectiveGoal != *r1.NewGoal {
		t.Errorf("effective must equal new goal when updated")
	}
	_ = baseline.ConfidenceNone
}

func rep(v int, n int) []int {
	out := make([]int, n)
	for i := range out {
		out[i] = v
	}
	return out
}
