package explain

import (
	"math"
	"testing"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/activity"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/readiness"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/sleep"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/stress"
)

var testMeta = Meta{
	ConfigHash:    "sha256:test",
	EngineVersion: "test",
	CalculatedAt:  time.Date(2026, 8, 10, 12, 0, 0, 0, time.UTC),
}

func sleepSummary(rem, deep, light int64, sleepingMs int64) domain.NightSummary {
	// time.Local is deliberate: the sleep package derives minute-of-day via
	// time.UnixMilli (machine-local), so the epoch must be built in the same
	// zone for the bedtime diff to be deterministic across runs.
	return domain.NightSummary{
		StartMs:    time.Date(2026, 8, 9, 23, 26, 0, 0, time.Local).UnixMilli(),
		EndMs:      time.Date(2026, 8, 10, 7, 26, 0, 0, time.Local).UnixMilli(),
		DurationMs: sleepingMs,
		RemMs:      rem,
		DeepMs:     deep,
		LightMs:    light,
	}
}

func TestSleepExplanationRecomposes(t *testing.T) {
	// B.2-style night: sleeping 480min, REM 38min (8%), Deep 96min (20%),
	// bedtime 23:26 (+86min) → sleep 90.
	const sleepingMs = int64(480 * 60000)
	rem := int64(math.Round(float64(sleepingMs) * 8 / 100))
	deep := int64(math.Round(float64(sleepingMs) * 20 / 100))
	light := sleepingMs - rem - deep
	res := sleep.Compute(sleepSummary(rem, deep, light, sleepingMs), 1320, 480, config.DefaultSleep())
	if res.Score != 90 {
		t.Fatalf("setup: sleep must be 90, got %d", res.Score)
	}
	ex := Sleep(res, sleepSummary(rem, deep, light, sleepingMs), 1320, 480, testMeta)
	// recompose: 100 − trunc(quality + bed + target)
	var discounts float64
	for _, s := range ex.Steps {
		switch s.Name {
		case "bedtime_discount", "duration_discount", "stage_quality_discount":
			discounts += s.Value
		}
	}
	recomposed := 100 - int(discounts) // truncation toward zero
	if recomposed != ex.Score {
		t.Errorf("recomposition: got %d want %d (discounts %v)", recomposed, ex.Score, discounts)
	}
	if ex.Score != 90 {
		t.Errorf("explanation score: got %d want 90", ex.Score)
	}
	if len(ex.Missing) != 0 {
		t.Errorf("no missing expected, got %v", ex.Missing)
	}
	// battery case: warning + missing, score 0
	bat := sleepSummary(rem, deep, light, sleepingMs)
	bat.BatteryDepleted = true
	exB := Sleep(sleep.Compute(bat, 1320, 480, config.DefaultSleep()), bat, 1320, 480, testMeta)
	if exB.Score != 0 || len(exB.Missing) == 0 || len(exB.Warnings) == 0 {
		t.Errorf("battery: score=%d missing=%v warnings=%v", exB.Score, exB.Missing, exB.Warnings)
	}
	// empty night
	exE := Sleep(sleep.Result{}, domain.NightSummary{}, 1320, 480, testMeta)
	if len(exE.Missing) == 0 || exE.Missing[0] != MissingSleepData {
		t.Errorf("empty night missing reason: %v", exE.Missing)
	}
	// degenerate window warning (N3 behavior)
	degen := sleepSummary(rem, deep, light, sleepingMs)
	degen.DegenerateWindow = true
	exD := Sleep(sleep.Compute(degen, 1320, 480, config.DefaultSleep()), degen, 1320, 480, testMeta)
	if len(exD.Warnings) == 0 {
		t.Error("degenerate window must produce a warning")
	}
}

func TestStressExplanationRecomposes(t *testing.T) {
	// B.2 series: baseline 40, trend 32.34 → stress 40
	daily := make([]float64, 21)
	for i := range daily {
		daily[i] = 49.575 - 0.9575*float64(i)
	}
	res := stress.New(config.DefaultStress()).Trend(daily)
	if res.Score != 40 {
		t.Fatalf("setup: stress must be 40, got %d", res.Score)
	}
	ex := Stress(res, testMeta)
	// recompose z → logistic → raw → round
	steep, mid := 0.72, 2.0
	logistic := 1.0 / (1.0 + math.Exp(-steep*(ex.step("z")-mid)))
	raw := 12.0 + 83.0*logistic
	if math.Abs(raw-ex.step("score_pre_round")) > 1e-9 {
		t.Errorf("raw recomposition: got %v want %v", raw, ex.step("score_pre_round"))
	}
	if int(math.Round(raw)) != ex.Score {
		t.Errorf("score recomposition: got %d want %d", int(math.Round(raw)), ex.Score)
	}
	// insufficient days
	ins := stress.New(config.DefaultStress()).Trend([]float64{40, 41})
	exI := Stress(ins, testMeta)
	if len(exI.Missing) == 0 || exI.Missing[0] != MissingHrvDays {
		t.Errorf("insufficient: %v", exI.Missing)
	}
}

func TestReadinessExplanationRecomposes(t *testing.T) {
	// B.2 pipeline: components sleep 87 / recovery 60 / rhr 100 / spo2 63 /
	// fatigue 78 → blend 78, no cap (today sleep 90).
	a := readiness.New(config.DefaultReadiness())
	rhr, rhrBase := 62.0, 64.67
	spo2, spo2Base := 95.2, 96.07
	b := a.Compute(90, 40, []int{85, 70, 0, 80}, &rhr, &rhrBase, &spo2, &spo2Base, []int{85, 70, 80})
	if b == nil || b.TotalScore != 78 {
		t.Fatalf("setup: readiness must be 78, got %+v", b)
	}
	fatigue := 78
	ex := Readiness(b, ReadinessInput{LastNightRhr: &rhr, RhrBaseline: &rhrBase,
		Spo2Tonight: &spo2, Spo2Baseline: &spo2Base, FatigueAvg: &fatigue}, 90, testMeta)

	// recompose the blend from components
	sum, weight := 0.0, 0.0
	for _, c := range ex.Components {
		sum += float64(c.NormalizedValue) * c.Weight
		weight += c.Weight
	}
	blended := int(math.Round(sum / weight))
	if blended != b.Blended {
		t.Errorf("blend recomposition: got %d want %d", blended, b.Blended)
	}
	if blended != ex.Score { // no cap in this case
		t.Errorf("score recomposition: got %d want %d", blended, ex.Score)
	}
	// verify raw inputs attached
	for _, c := range ex.Components {
		if c.Key == "rhr" && (c.RawValue == nil || c.BaselineValue == nil) {
			t.Error("rhr component must carry raw + baseline")
		}
		if c.Key == "spo2" && (c.RawValue == nil || c.BaselineValue == nil) {
			t.Error("spo2 component must carry raw + baseline")
		}
	}
	// optional-component missing reasons
	b2 := a.Compute(90, 40, []int{85, 70, 0, 80}, nil, nil, nil, nil, nil)
	ex2 := Readiness(b2, ReadinessInput{}, 90, testMeta)
	found := map[MissingReason]bool{}
	for _, m := range ex2.Missing {
		found[m] = true
	}
	if !found[MissingRhrBaseline] || !found[MissingSpo2Baseline] || !found[MissingFatigueData] {
		t.Errorf("missing reasons: %v", ex2.Missing)
	}
	// cap case: today sleep 45 → cap 58
	capRhr, capBase := 60.0, 60.0
	bc := a.Compute(45, 40, []int{80}, &capRhr, &capBase, nil, nil, []int{80})
	if bc.CapApplied == nil || *bc.CapApplied != 58 {
		t.Fatalf("setup: cap must apply (58), got %+v", bc.CapApplied)
	}
	if bc.TotalScore != 58 {
		t.Fatalf("setup: capped total must be 58, got %d", bc.TotalScore)
	}
	exC := Readiness(bc, ReadinessInput{LastNightRhr: &capRhr, RhrBaseline: &capBase}, 45, testMeta)
	if exC.Score != 58 {
		t.Errorf("capped explanation score: got %d want 58", exC.Score)
	}
}

func TestActivityExplanationRecomposes(t *testing.T) {
	// B.2: wearable 168 + session 50 = 218 vs goal 280 → 78
	a := activity.New(config.DefaultActivity())
	res := a.Calculate(168, 50, 7000, 55)
	if res.ActivityScore != 78 {
		t.Fatalf("setup: activity must be 78, got %d", res.ActivityScore)
	}
	ex := Activity(res, testMeta)
	ratio := float64(res.TotalKcal) / float64(res.GoalKcal)
	recomposed := int(math.Round(100 * ratio))
	if recomposed != ex.Score {
		t.Errorf("recomposition: got %d want %d", recomposed, ex.Score)
	}
	// zero data
	ex0 := Activity(a.Calculate(0, 0, 7000, 0), testMeta)
	if ex0.Score != 0 || len(ex0.Missing) == 0 {
		t.Errorf("zero data: score=%d missing=%v", ex0.Score, ex0.Missing)
	}
}

func (e Explanation) step(name string) float64 {
	for _, s := range e.Steps {
		if s.Name == name {
			return s.Value
		}
	}
	return math.NaN()
}
