package engine

import (
	"testing"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/night"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/activity"
)

var br = time.FixedZone("BRT", -3*3600)

// B.2 end-to-end: user u1, day 2026-08-10.
//   - sleep tonight 90 (bedtime +86min → discount 5; REM 8% → discount 5),
//     history [85,70,0,80] → histAvg 79 → sleepComponent 87
//   - stress 40 (daily averages shaped so Trend yields exactly 40)
//   - RHR 62 vs baseline 64.67 → 100; SpO2 95.2 vs 96.07 → 63
//   - fatigue [85,70,80] → avg 78 → 78
//
// Expected readiness 78 (hand-derived in docs/wellness-golden-dataset.md B.2).
func TestCalculateDayB2(t *testing.T) {
	// 21 daily HRV averages, linear 49.575 − 0.9575·i (i=0..20):
	// baseline = mean = 40.0; linear-weighted trend (pos 18) = 32.34
	// → z = (ln40−ln32.34)/0.20 ≈ 1.0625 → score 40 (lnSd clamps to 0.20).
	daily := make([]float64, 21)
	for i := range daily {
		daily[i] = 49.575 - 0.9575*float64(i)
	}

	rhr := 62.0
	rhrBase := 64.67
	spo2 := 95.2
	spo2Base := 96.07

	res, err := CalculateDay(Input{
		PersonID: "u1",
		Date:     time.Date(2026, 8, 10, 15, 0, 0, 0, br),
		Location: br,
		Segments: []domain.Segment{
			// 23:26 → 07:26, sleeping 480min: REM 38min (8%), Deep 96min (20%)
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
	}, DefaultConfigs())
	if err != nil {
		t.Fatal(err)
	}

	if res.Night.IsEmpty() {
		t.Fatal("night must not be empty")
	}
	if res.Sleep.Score != 90 {
		t.Errorf("sleep: got %d want 90", res.Sleep.Score)
	}
	if res.Stress.Score != 40 {
		t.Errorf("stress: got %d want 40", res.Stress.Score)
	}
	if res.Readiness == nil {
		t.Fatal("readiness must not be nil")
	}
	if res.Readiness.SleepHistoricalAvg != 79 {
		t.Errorf("histAvg: got %d want 79", res.Readiness.SleepHistoricalAvg)
	}
	if res.Readiness.SleepComponent != 87 {
		t.Errorf("sleepComponent: got %d want 87", res.Readiness.SleepComponent)
	}
	if res.Readiness.TotalScore != 78 {
		t.Errorf("readiness: got %d want 78", res.Readiness.TotalScore)
	}
	// activity: kcal 168 + 50 = 218 vs goal 280 → round(100*218/280)=78
	if res.Activity.ActivityScore != 78 {
		t.Errorf("activity: got %d want 78", res.Activity.ActivityScore)
	}
	if res.Activity.GoalKcal != 280 {
		t.Errorf("goalKcal: got %d want 280", res.Activity.GoalKcal)
	}
}

func TestCalculateDayGates(t *testing.T) {
	// no person → ErrNoData
	if _, err := CalculateDay(Input{}, DefaultConfigs()); err == nil {
		t.Error("empty person must error")
	}
	// no stress data → readiness nil (gated), sleep 0, activity 0
	res, err := CalculateDay(Input{
		PersonID: "u1",
		Date:     time.Date(2026, 8, 10, 15, 0, 0, 0, br),
		Location: br,
		Segments: []domain.Segment{
			{StartMs: ms(2026, 8, 9, 22, 0), EndMs: ms(2026, 8, 10, 7, 0), Stage: domain.StageLight},
		},
	}, DefaultConfigs())
	if err != nil {
		t.Fatal(err)
	}
	if res.Readiness != nil {
		t.Error("readiness must be gated (stress 0)")
	}
	if res.Sleep.Score == 0 {
		t.Error("sleep should compute from the night (score > 0)")
	}
	if res.Activity.ActivityScore != 0 {
		t.Errorf("activity: got %d want 0 (no steps)", res.Activity.ActivityScore)
	}
}

func ms(y int, mo time.Month, d, h, mi int) int64 {
	return time.Date(y, mo, d, h, mi, 0, 0, br).UnixMilli()
}

// ensure night.BatterySample import used in signature parity
var _ = night.BatterySample{}
