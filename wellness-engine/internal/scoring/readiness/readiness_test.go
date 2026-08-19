package readiness

import (
	"strconv"
	"strings"
	"testing"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/golden"
)

func TestGoldenReadinessOracle(t *testing.T) {
	oracle, err := golden.Load()
	if err != nil {
		t.Fatal(err)
	}
	a := New(config.DefaultReadiness())

	// sleep aggregate: today 85, hist 70 → 81
	{
		entry := oracle["readiness_sleep_aggregate"].(map[string]any)
		got := a.SleepAggregateScore(85, 70)
		if want := int(entry["output"].(float64)); got != want {
			t.Errorf("sleepAggregate: got %d want %d", got, want)
		}
	}

	// fatigue lerp across knots
	{
		entry := oracle["readiness_fatigue_lerp"].(map[string]any)
		inputs := entry["input"].(map[string]any)["avgSleepScores"].([]any)
		output := entry["output"].(map[string]any)
		for _, iv := range inputs {
			avg := int(iv.(float64))
			got := a.ScoreFatigueFromAverage(avg)
			want := int(output[key(avg)].(float64))
			if got != want {
				t.Errorf("fatigue(%d): got %d want %d", avg, got, want)
			}
		}
	}

	// caps: blend 90 with todaySleep [10,35,45,55,70]
	{
		entry := oracle["readiness_caps"].(map[string]any)
		scores := entry["input"].(map[string]any)["todaySleepScores"].([]any)
		output := entry["output"].(map[string]any)
		for _, iv := range scores {
			s := int(iv.(float64))
			got := a.ApplyReadinessCaps(90, s)
			want := int(output[key(s)].(float64))
			if got != want {
				t.Errorf("cap(%d): got %d want %d", s, got, want)
			}
		}
	}

	// RHR: [58,65,70,75,80] vs baseline 65 → [100,100,36,0,0]
	{
		entry := oracle["readiness_rhr"].(map[string]any)
		rhrs := entry["input"].(map[string]any)["lastNightRhr"].([]any)
		output := entry["output"].(map[string]any)
		for _, rv := range rhrs {
			r := rv.(float64)
			got := a.ScoreRhrVsBaseline(r, 65.0)
			want := int(output[keyFloat(r)].(float64))
			if got != want {
				t.Errorf("rhr(%v): got %d want %d", r, got, want)
			}
		}
	}

	// SpO2 absolute
	{
		entry := oracle["readiness_spo2_absolute"].(map[string]any)
		pcts := entry["input"].(map[string]any)["avgPct"].([]any)
		output := entry["output"].(map[string]any)
		for _, pv := range pcts {
			p := pv.(float64)
			got := a.ScoreSpo2(p, nil)
			want := int(output[keyFloat(p)].(float64))
			if got != want {
				t.Errorf("spo2 abs(%v): got %d want %d", p, got, want)
			}
		}
	}

	// SpO2 personal baseline 96
	{
		entry := oracle["readiness_spo2_personal"].(map[string]any)
		pcts := entry["input"].(map[string]any)["avgPct"].([]any)
		output := entry["output"].(map[string]any)
		b := 96.0
		for _, pv := range pcts {
			p := pv.(float64)
			got := a.ScoreSpo2(p, &b)
			want := int(output[keyFloat(p)].(float64))
			if got != want {
				t.Errorf("spo2 pers(%v): got %d want %d", p, got, want)
			}
		}
	}

	// blends
	{
		got := a.WeightedBlend([]Component{
			{"sleep", 80, a.Cfg.WeightSleep},
			{"recovery", 70, a.Cfg.WeightRecovery},
			{"rhr", 90, a.Cfg.WeightRhr},
			{"spo2", 100, a.Cfg.WeightSpo2},
			{"fatigue", 85, a.Cfg.WeightFatigue},
		})
		if want := int(oracle["readiness_blend_all"].(map[string]any)["output"].(float64)); got != want {
			t.Errorf("blend all: got %d want %d", got, want)
		}
		got = a.WeightedBlend([]Component{
			{"sleep", 80, a.Cfg.WeightSleep},
			{"recovery", 70, a.Cfg.WeightRecovery},
		})
		if want := int(oracle["readiness_blend_missing_optional"].(map[string]any)["output"].(float64)); got != want {
			t.Errorf("blend partial: got %d want %d", got, want)
		}
	}
}

func TestFullPipelineGates(t *testing.T) {
	a := New(config.DefaultReadiness())
	// service gate: todaySleepScore <= 0 → nil
	if b := a.Compute(0, 40, []int{80, 70}, nil, nil, nil, nil, nil); b != nil {
		t.Error("today sleep 0 must yield nil (no data)")
	}
	// full pipeline with all components — B.2 hand-derived case:
	// today 90, history [85,70,0,80] → histAvg 79; stress 40; rhr 62 vs 64.67
	// → 100; spo2 95.2 vs 96.07 → 63; fatigue avg 78 → 78; blend 78; no cap.
	rhrBase := 64.67
	spo2Base := 96.07
	spo2 := 95.2
	rhr := 62.0
	b := a.Compute(90, 40, []int{85, 70, 0, 80}, &rhr, &rhrBase, &spo2, &spo2Base, []int{85, 70, 80})
	if b == nil {
		t.Fatal("expected breakdown")
	}
	if b.SleepHistoricalAvg != 79 {
		t.Errorf("histAvg: got %d want 79", b.SleepHistoricalAvg)
	}
	if b.SleepComponent != 87 {
		t.Errorf("sleepComponent: got %d want 87", b.SleepComponent)
	}
	if b.RecoveryComponent != 60 {
		t.Errorf("recovery: got %d want 60", b.RecoveryComponent)
	}
	if b.RhrComponent == nil || *b.RhrComponent != 100 {
		t.Errorf("rhr: got %v want 100", b.RhrComponent)
	}
	if b.Spo2Component == nil || *b.Spo2Component != 63 {
		t.Errorf("spo2: got %v want 63", b.Spo2Component)
	}
	if b.FatigueComponent == nil || *b.FatigueComponent != 78 {
		t.Errorf("fatigue: got %v want 78", b.FatigueComponent)
	}
	if b.TotalScore != 78 {
		t.Errorf("total: got %d want 78", b.TotalScore)
	}
}

func key(i int) string { return strconv.Itoa(i) }

// keyFloat reproduces Dart's jsonEncode number formatting used in the
// oracle ("58.0", "95.5", "70.0").
func keyFloat(f float64) string {
	s := strconv.FormatFloat(f, 'f', -1, 64)
	if !strings.Contains(s, ".") {
		s += ".0"
	}
	return s
}
