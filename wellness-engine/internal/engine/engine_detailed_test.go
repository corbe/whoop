package engine

import (
	"strings"
	"testing"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/goals"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/activity"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/versioning"
)

// B.2 through the DETAILED path must reproduce EXACTLY the same scores
// (sleep 90, stress 40, readiness 78, activity 78) plus metadata and
// explanations. Goal inputs are omitted → no goal updates, calibrated
// defaults for bed/target.
func TestCalculateDayDetailedB2(t *testing.T) {
	in := b2Input()
	bundle, err := CalculateDayDetailed(in, DefaultConfigs())
	if err != nil {
		t.Fatal(err)
	}
	if bundle.Scores.Sleep.Score != 90 {
		t.Errorf("sleep: got %d want 90", bundle.Scores.Sleep.Score)
	}
	if bundle.Scores.Stress.Score != 40 {
		t.Errorf("stress: got %d want 40", bundle.Scores.Stress.Score)
	}
	if bundle.Scores.Readiness == nil || bundle.Scores.Readiness.TotalScore != 78 {
		t.Errorf("readiness: got %+v want 78", bundle.Scores.Readiness)
	}
	if bundle.Scores.Activity.ActivityScore != 78 {
		t.Errorf("activity: got %d want 78", bundle.Scores.Activity.ActivityScore)
	}

	// metadata
	if !strings.HasPrefix(bundle.Metadata.ConfigHash, "sha256:") || len(bundle.Metadata.ConfigHash) != 71 {
		t.Errorf("config hash malformed: %q", bundle.Metadata.ConfigHash)
	}
	for _, key := range []versioning.Key{versioning.KeySleep, versioning.KeyStress,
		versioning.KeyReadiness, versioning.KeyActivity, versioning.KeyGoalSteps, versioning.KeyGoalSleep} {
		if v, ok := bundle.Metadata.FormulaVersions[key]; !ok || v != 1 {
			t.Errorf("formula version for %s: got %v want 1", key, v)
		}
	}
	if bundle.Metadata.EngineVersion == "" {
		t.Error("engine version must be set")
	}

	// explanations present with correct scores
	if bundle.Explanations[versioning.KeySleep].Score != 90 {
		t.Errorf("sleep explanation: %d", bundle.Explanations[versioning.KeySleep].Score)
	}
	if bundle.Explanations[versioning.KeyReadiness].Score != 78 {
		t.Errorf("readiness explanation: %d", bundle.Explanations[versioning.KeyReadiness].Score)
	}
	// recomposition from readiness explanation components
	ex := bundle.Explanations[versioning.KeyReadiness]
	sum, weight := 0.0, 0.0
	for _, c := range ex.Components {
		sum += float64(c.NormalizedValue) * c.Weight
		weight += c.Weight
	}
	if got := int(sum/weight + 0.5); got != 78 {
		t.Errorf("explanation recomposition: got %d want 78", got)
	}
}

// Goal wiring through the detailed path: steps goal 9000 → activity uses the
// effective goal; sleep goal shift applies.
func TestCalculateDayDetailedGoals(t *testing.T) {
	now := time.Date(2026, 8, 10, 12, 0, 0, 0, time.UTC)
	past := now.Add(-8 * 24 * time.Hour)

	in := b2Input()
	in.GoalStepSamples = rep(9000, 30)
	in.GoalPriorSteps = 7500
	in.GoalMaxDailySteps = 15000
	in.GoalState = goals.StepsState{CurrentGoal: 7000, LastAutoUpdateAt: &past}
	in.GoalSteps = 7000 // would be used only if goals were skipped
	in.Now = now

	bundle, err := CalculateDayDetailed(in, DefaultConfigs())
	if err != nil {
		t.Fatal(err)
	}
	if !bundle.Goals.Steps.Updated || bundle.Goals.Steps.NewGoal == nil || *bundle.Goals.Steps.NewGoal != 9000 {
		t.Fatalf("steps goal must update to 9000: %+v", bundle.Goals.Steps)
	}
	// activity must use the EFFECTIVE goal (9000 → goalKcal 360)
	if bundle.Scores.Activity.GoalSteps != 9000 {
		t.Errorf("activity goalSteps: got %d want 9000 (effective goal)", bundle.Scores.Activity.GoalSteps)
	}
	if bundle.Scores.Activity.GoalKcal != 360 {
		t.Errorf("goalKcal: got %d want 360", bundle.Scores.Activity.GoalKcal)
	}
	// scores unchanged by goal wiring (B.2 inputs)
	if bundle.Scores.Sleep.Score != 90 || bundle.Scores.Stress.Score != 40 {
		t.Errorf("scores changed: sleep=%d stress=%d", bundle.Scores.Sleep.Score, bundle.Scores.Stress.Score)
	}
}

func rep(v int, n int) []int {
	out := make([]int, n)
	for i := range out {
		out[i] = v
	}
	return out
}

// b2Input reproduces the B.2 golden day (docs/wellness-golden-dataset.md B.2).
func b2Input() Input {
	daily := make([]float64, 21)
	for i := range daily {
		daily[i] = 49.575 - 0.9575*float64(i)
	}
	rhr, rhrBase := 62.0, 64.67
	spo2, spo2Base := 95.2, 96.07
	return Input{
		PersonID: "u1",
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
