// Engine — deterministic day calculation (pure orchestration).
//
// Wires the pure layers in the dependency order proven by the audit
// (docs/wellness-formula-dependencies.md): night summary → sleep score;
// HRV daily averages → stress; sleep history + stress + RHR/SpO2 baselines
// → readiness; readiness + steps/session kcal → activity. Goal auto-update
// (F-08/F-09) runs FIRST (before the day's scores), mirroring
// WellnessScores.calculateRings (wellness_scores.dart:58).
//
// Determinism contract: same Input + same Configs + same timezone +
// same explicit Now → identical output. No I/O here; persistence adapters
// come later (STAGE 14).
package engine

import (
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/explain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/goals"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/night"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/activity"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/readiness"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/sleep"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/stress"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/versioning"
)

// Configs bundles the versioned configuration for a calculation.
type Configs struct {
	Sleep     config.Sleep
	Stress    config.Stress
	Readiness config.Readiness
	Activity  config.Activity
	Baseline  config.Baseline
	Goals     goals.Config
}

// DefaultConfigs returns the parity defaults (ScoreCalibration.current).
func DefaultConfigs() Configs {
	return Configs{
		Sleep:     config.DefaultSleep(),
		Stress:    config.DefaultStress(),
		Readiness: config.DefaultReadiness(),
		Activity:  config.DefaultActivity(),
		Baseline:  config.DefaultBaseline(),
		Goals:     goals.DefaultConfig(),
	}
}

// Input is everything "calculate day" needs. Values the app derives from its
// DB are supplied here (the persistence adapters fill them in STAGE 14).
type Input struct {
	PersonID string
	Date     time.Time
	Location *time.Location

	// Night data (F-12 inputs)
	Segments []domain.Segment
	HRVMs    []float64 // HRV samples (ms)
	Battery  []night.BatterySample

	// Stress (F-02): daily averages (ascending local days; last = anchor day).
	DailyHrvAverages     []float64
	InstantHrvSamples    []float64
	InstantHrvTimestamps []int64

	// Sleep history for readiness (D-1..D-4 scores; 0 = no data).
	SleepHistoryScores []int
	// Fatigue history (D-1..D-3 scores; subset of the above).
	FatigueHistoryScores []int

	// RHR / SpO2 (optional; nil = component absent)
	LastNightRhr *float64
	RhrBaseline  *float64
	Spo2Tonight  *float64
	Spo2Baseline *float64

	// Activity (F-04)
	StepsRecords []activity.StepsRecord
	SessionKcal  int
	GoalSteps    int // <= 0 → default 7000 (or demographic prior, resolved by caller)

	// Goal auto-update (F-08/F-09) — optional. When GoalStepSamples /
	// BedtimeMinutes / DurationMinutes are nil, goal updates are skipped and
	// the current goals above / calibrated defaults are used as-is.
	GoalStepSamples     []int // daily step peaks D-1..D-30
	GoalPriorSteps      int   // demographic prior (7500 etc.)
	GoalMaxDailySteps   int   // maxDailyStepsForAge (12000 if age>=65)
	GoalState           goals.StepsState
	BedtimeMinutes      []int // normalized bedtimes D-1..D-21
	DurationMinutes     []int // effective sleep minutes D-1..D-21
	SleepGoalState      goals.SleepState
	SleepBedTimeCurrent *int // prefs/current values (may be updated)
	SleepTargetCurrent  *int
	// Now is the explicit wall-clock for cooldown/manual-override checks
	// (zero → Date, deterministic but not wall-clock accurate).
	Now time.Time
}

// DayResult is the deterministic output of a day calculation.
type DayResult struct {
	Night        domain.NightSummary
	Sleep        sleep.Result
	Stress       stress.TrendResult
	InstantHrvMs float64
	Readiness    *readiness.Breakdown // nil when gated (no sleep/stress data)
	Activity     activity.DayResult
}

// CalculateDay runs the full pure pipeline with the calibrated defaults for
// bed/target/goals. Errors are ErrNoData / ErrInvalidInput (domain package).
func CalculateDay(in Input, cfgs Configs) (*DayResult, error) {
	if in.PersonID == "" {
		return nil, domain.NoData("person id empty")
	}
	if in.Location == nil {
		in.Location = time.Local
	}
	return scoreDay(in, cfgs,
		cfgs.Sleep.DefaultBedTimeMinutes,
		cfgs.Sleep.DefaultSleepTargetMinutes,
		in.GoalSteps), nil
}

// ── Detailed path (STAGE 11-13) ────────────────────────────────────────────

// GoalResults captures the F-08/F-09 update outcomes.
type GoalResults struct {
	Steps goals.StepsResult
	Sleep goals.SleepResult
}

// ResultMetadata is the reproducibility metadata (STAGE 12).
type ResultMetadata struct {
	// FormulaVersions maps every formula key to its ACTIVE version (from the
	// centralized registry; see versioning.DefaultRegistry).
	FormulaVersions map[versioning.Key]int
	ConfigHash      string
	EngineVersion   string
	CalculatedAt    time.Time
}

// QualityReport aggregates pipeline quality flags from all explanations.
type QualityReport struct {
	Warnings []explain.Warning
	Missing  []explain.MissingReason
}

// CalculationBundle is the full deterministic output (STAGE 13).
type CalculationBundle struct {
	Scores       DayResult
	Goals        GoalResults
	Metadata     ResultMetadata
	Explanations map[versioning.Key]explain.Explanation
	Quality      QualityReport
}

// CalculateDayDetailed mirrors the app's ring calculation order:
// goal auto-update FIRST, then scores with the EFFECTIVE goals
// (wellness_scores.dart:58). Returns the bundle with metadata + explanations.
func CalculateDayDetailed(in Input, cfgs Configs) (*CalculationBundle, error) {
	if in.PersonID == "" {
		return nil, domain.NoData("person id empty")
	}
	if in.Location == nil {
		in.Location = time.Local
	}
	now := in.Now
	if now.IsZero() {
		now = in.Date
	}
	registry := versioning.DefaultRegistry()

	// 1. Goal auto-update (F-08/F-09) — before scores, mirroring the app.
	var gs goals.StepsResult
	var sl goals.SleepResult
	runStepsGoals := in.GoalStepSamples != nil
	runSleepGoals := in.BedtimeMinutes != nil
	if runStepsGoals {
		gs = goals.UpdateSteps(goals.StepsInput{
			DailySamples:  in.GoalStepSamples,
			Prior:         in.GoalPriorSteps,
			MaxDailySteps: in.GoalMaxDailySteps,
			State:         in.GoalState,
			Now:           now,
			Cfg:           cfgs.Goals,
		})
	}
	if runSleepGoals {
		sl = goals.UpdateSleep(goals.SleepInput{
			BedtimeMinutes:   in.BedtimeMinutes,
			DurationMinutes:  in.DurationMinutes,
			PriorBedTime:     in.goalPriorBedTime(cfgs),
			PriorSleepTarget: in.goalPriorSleepTarget(cfgs),
			State:            in.SleepGoalState,
			Now:              now,
			Cfg:              cfgs.Goals,
		})
	}

	// 2. Effective goals (post-update), matching the app's persisted values.
	bed := cfgs.Sleep.DefaultBedTimeMinutes
	target := cfgs.Sleep.DefaultSleepTargetMinutes
	if in.SleepBedTimeCurrent != nil {
		bed = *in.SleepBedTimeCurrent
	}
	if in.SleepTargetCurrent != nil {
		target = *in.SleepTargetCurrent
	}
	if runSleepGoals {
		if sl.Updated {
			bed = *sl.NewBedTime
			target = *sl.NewSleepTarget
		}
	}
	goalSteps := in.GoalSteps
	if runStepsGoals {
		goalSteps = gs.EffectiveGoal
	}

	// 3. Scores with the effective goals.
	res := scoreDay(in, cfgs, bed, target, goalSteps)

	// 4. Metadata + explanations.
	meta := ResultMetadata{
		FormulaVersions: map[versioning.Key]int{
			versioning.KeySleep:     registry.Active(versioning.KeySleep).Version,
			versioning.KeyStress:    registry.Active(versioning.KeyStress).Version,
			versioning.KeyReadiness: registry.Active(versioning.KeyReadiness).Version,
			versioning.KeyActivity:  registry.Active(versioning.KeyActivity).Version,
			versioning.KeyGoalSteps: registry.Active(versioning.KeyGoalSteps).Version,
			versioning.KeyGoalSleep: registry.Active(versioning.KeyGoalSleep).Version,
		},
		ConfigHash: versioning.HashConfig(versioning.ConfigSet{
			Sleep:     cfgs.Sleep,
			Stress:    cfgs.Stress,
			Readiness: cfgs.Readiness,
			Activity:  cfgs.Activity,
			Baseline:  cfgs.Baseline,
			Goals:     cfgs.Goals,
		}),
		EngineVersion: versioning.EngineVersion,
		CalculatedAt:  now,
	}
	em := explain.Meta{ConfigHash: meta.ConfigHash, EngineVersion: meta.EngineVersion, CalculatedAt: now}

	exps := map[versioning.Key]explain.Explanation{
		versioning.KeySleep:    explain.Sleep(res.Sleep, res.Night, bed, target, em),
		versioning.KeyStress:   explain.Stress(res.Stress, em),
		versioning.KeyActivity: explain.Activity(res.Activity, em),
	}
	if res.Readiness != nil {
		var fatigueAvg *int
		if res.Readiness.FatigueAvgSleep != nil {
			fatigueAvg = res.Readiness.FatigueAvgSleep
		}
		exps[versioning.KeyReadiness] = explain.Readiness(res.Readiness, explain.ReadinessInput{
			LastNightRhr: in.LastNightRhr, RhrBaseline: in.RhrBaseline,
			Spo2Tonight: in.Spo2Tonight, Spo2Baseline: in.Spo2Baseline,
			FatigueAvg: fatigueAvg,
		}, res.Sleep.Score, em)
	}

	quality := QualityReport{}
	for _, ex := range exps {
		quality.Warnings = append(quality.Warnings, ex.Warnings...)
		quality.Missing = append(quality.Missing, ex.Missing...)
	}

	return &CalculationBundle{
		Scores:       *res,
		Goals:        GoalResults{Steps: gs, Sleep: sl},
		Metadata:     meta,
		Explanations: exps,
		Quality:      quality,
	}, nil
}

// goalPriorBedTime/SleepTarget default the sleep-goal priors to the
// calibrated defaults when the caller did not supply demographic priors.
func (in Input) goalPriorBedTime(cfgs Configs) int { return cfgs.Sleep.DefaultBedTimeMinutes }
func (in Input) goalPriorSleepTarget(cfgs Configs) int {
	return cfgs.Sleep.DefaultSleepTargetMinutes
}

// scoreDay runs the pure scoring pipeline (shared by both entry points).
func scoreDay(in Input, cfgs Configs, bedTimeMinutes, sleepTargetMinutes, goalSteps int) *DayResult {
	// 1. Night summary (F-12)
	nightSummary := night.ForNight(night.Input{
		Segments:   in.Segments,
		HRVMs:      in.HRVMs,
		Battery:    in.Battery,
		Location:   in.Location,
		AnchorDate: in.Date,
	})

	// 2. Sleep score (F-01)
	sleepRes := sleep.Compute(nightSummary, bedTimeMinutes, sleepTargetMinutes, cfgs.Sleep)

	// 3. Stress (F-02)
	stressAlgo := stress.New(cfgs.Stress)
	stressRes := stressAlgo.Trend(in.DailyHrvAverages)
	instant := stressAlgo.InstantHRVMs(in.InstantHrvSamples,
		in.Date.UnixMilli(), in.InstantHrvTimestamps)

	// 4. Readiness (F-03) — gates: stressScore > 0 && todaySleepScore > 0
	var readinessRes *readiness.Breakdown
	if stressRes.Score > 0 && sleepRes.Score > 0 {
		readinessAlgo := readiness.New(cfgs.Readiness)
		readinessRes = readinessAlgo.Compute(
			sleepRes.Score,
			stressRes.Score,
			in.SleepHistoryScores,
			in.LastNightRhr,
			in.RhrBaseline,
			in.Spo2Tonight,
			in.Spo2Baseline,
			in.FatigueHistoryScores,
		)
	}

	// 5. Activity (F-04)
	activityAlgo := activity.New(cfgs.Activity)
	agg := activityAlgo.AggregateSteps(
		activityAlgo.PreferWearable(in.StepsRecords),
	)
	readinessScore := 0
	if readinessRes != nil {
		readinessScore = readinessRes.TotalScore
	}
	activityRes := activityAlgo.Calculate(agg.Calories, in.SessionKcal, goalSteps, readinessScore)

	return &DayResult{
		Night:        nightSummary,
		Sleep:        sleepRes,
		Stress:       stressRes,
		InstantHrvMs: instant,
		Readiness:    readinessRes,
		Activity:     activityRes,
	}
}
