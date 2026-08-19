package stress

import (
	"math"
	"testing"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/golden"
)

func TestGoldenStressOracle(t *testing.T) {
	oracle, err := golden.Load()
	if err != nil {
		t.Fatal(err)
	}
	algo := New(config.DefaultStress())

	// stress_healthy_21d / stress_stressed_21d: trend pipeline
	for _, name := range []string{"stress_healthy_21d", "stress_stressed_21d"} {
		entry := oracle[name].(map[string]any)
		input := entry["input"].(map[string]any)
		raw := input["dailyAveragesMs"].([]any)
		daily := make([]float64, len(raw))
		for i, v := range raw {
			daily[i] = v.(float64)
		}
		res := algo.Trend(daily)
		wantScore := int(entry["output"].(map[string]any)["stressScore"].(float64))
		if res.Score != wantScore {
			t.Errorf("%s: score got %d want %d", name, res.Score, wantScore)
		}
		if !res.Sufficient {
			t.Errorf("%s: expected sufficient", name)
		}
		assertNear(t, name+".baseline", res.BaselineMs, entry["baselineMs"].(float64))
		assertNear(t, name+".lnSd", res.BaselineLnSd, entry["baselineLnSd"].(float64))
		assertNear(t, name+".trend", res.TrendMs, entry["trendMs"].(float64))
	}

	// stress_insufficient_days: service returns 0 + downCount
	{
		entry := oracle["stress_insufficient_days"].(map[string]any)
		input := entry["input"].(map[string]any)
		raw := input["dailyAveragesMs"].([]any)
		daily := make([]float64, len(raw))
		for i, v := range raw {
			daily[i] = v.(float64)
		}
		res := algo.Trend(daily)
		if res.Sufficient {
			t.Error("insufficient days must be reported insufficient")
		}
		if res.Score != 0 {
			t.Errorf("score: got %d want 0", res.Score)
		}
		if res.DownCount != int(entry["output"].(map[string]any)["downCount"].(float64)) {
			t.Errorf("downCount: got %d want 1", res.DownCount)
		}
	}

	// stress_z_edge_2x: observed >= 2*baseline → z = -0.4 → score 24.5200...
	{
		entry := oracle["stress_z_edge_2x"].(map[string]any)
		wantZ := entry["zScore"].(float64)
		gotZ := algo.ZScore(40, 85, 0.25)
		if gotZ != wantZ {
			t.Errorf("z edge: got %v want %v", gotZ, wantZ)
		}
		wantScore := entry["scoreFromZ"].(float64)
		gotScore := algo.ScoreFromZ(gotZ)
		if math.Abs(gotScore-wantScore) > 1e-9 {
			t.Errorf("scoreFromZ: got %v want %v", gotScore, wantScore)
		}
	}

	// stress_sanitize_clamp: observed 100 with baseline 40 → 62.0 (40*1.55)
	{
		entry := oracle["stress_sanitize_clamp"].(map[string]any)
		got := algo.SanitizeObservedMs(40, 100)
		want := entry["sanitizedMs"].(float64)
		if got != want {
			t.Errorf("sanitize: got %v want %v", got, want)
		}
	}

	// stress_lnsd_single_day: n<2 → defaultLnSd 0.22
	{
		entry := oracle["stress_lnsd_single_day"].(map[string]any)
		got := algo.LnSdFromDailyMs([]float64{42.0})
		want := entry["lnSd"].(float64)
		if got != want {
			t.Errorf("lnSd single: got %v want %v", got, want)
		}
	}
}

func TestInstantHRVGeometricMean(t *testing.T) {
	algo := New(config.DefaultStress())
	// samples at t=0 (ln window 15min from now=0 covers all) → exp(mean(ln))
	samples := []float64{40, 45, 50}
	ts := []int64{-600000, -300000, 0}
	got := algo.InstantHRVMs(samples, 0, ts)
	want := math.Exp((math.Log(40) + math.Log(45) + math.Log(50)) / 3)
	if math.Abs(got-want) > 1e-9 {
		t.Errorf("instant HRV: got %v want %v", got, want)
	}
	// no samples in any window → 0
	if got := algo.InstantHRVMs([]float64{40}, 0, []int64{-200 * 60 * 1000}); got != 0 {
		t.Errorf("empty windows: got %v want 0", got)
	}
}

func assertNear(t *testing.T, name string, got, want float64) {
	t.Helper()
	if math.Abs(got-want) > 1e-9*math.Max(1, math.Abs(want)) {
		t.Errorf("%s: got %v want %v", name, got, want)
	}
}
