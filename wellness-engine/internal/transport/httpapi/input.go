// rawInputDTO → engine.Input conversion (mode B stateless input).
package httpapi

import (
	"fmt"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/activity"
)

func (r *rawInputDTO) toEngineInput(day time.Time) (engine.Input, error) {
	loc := time.Local
	if r.Timezone != "" {
		l, err := time.LoadLocation(r.Timezone)
		if err != nil {
			return engine.Input{}, fmt.Errorf("timezone %q: %w", r.Timezone, err)
		}
		loc = l
	}
	segments := make([]domain.Segment, len(r.Segments))
	for i, s := range r.Segments {
		segments[i] = domain.Segment{StartMs: s.StartMs, EndMs: s.EndMs, Stage: domain.Stage(s.Stage)}
	}
	steps := make([]activity.StepsRecord, len(r.Steps))
	for i, s := range r.Steps {
		steps[i] = activity.StepsRecord{
			Value: s.Value, Calories: s.Calories, DistanceM: s.DistanceM,
			Timestamp: s.Timestamp, Device: domain.DeviceSource(s.Device),
		}
	}
	in := engine.Input{
		Date:                 day,
		Location:             loc,
		Segments:             segments,
		DailyHrvAverages:     r.DailyHrvAverages,
		SleepHistoryScores:   r.SleepHistoryScores,
		FatigueHistoryScores: r.FatigueHistoryScores,
		LastNightRhr:         r.LastNightRhr,
		RhrBaseline:          r.RhrBaseline,
		Spo2Tonight:          r.Spo2Tonight,
		Spo2Baseline:         r.Spo2Baseline,
		StepsRecords:         steps,
		SessionKcal:          r.SessionKcal,
		GoalSteps:            r.GoalSteps,
	}
	// goal auto-update inputs (optional; nil slices = goals skipped)
	if r.GoalStepSamples != nil {
		in.GoalStepSamples = r.GoalStepSamples
		in.GoalPriorSteps = r.GoalPriorSteps
		in.GoalMaxDailySteps = r.GoalMaxDailySteps
		in.GoalState.CurrentGoal = r.GoalCurrentSteps
		in.GoalState.LastAutoUpdateAt = msToTime(r.GoalLastAutoUpdateAt)
		in.GoalState.ManualOverrideAt = msToTime(r.GoalManualOverrideAt)
	}
	if r.BedtimeMinutes != nil {
		in.BedtimeMinutes = r.BedtimeMinutes
		in.DurationMinutes = r.DurationMinutes
		in.SleepGoalState.CurrentBedTime = r.SleepCurrentBedTime
		in.SleepGoalState.CurrentSleepTarget = r.SleepCurrentTarget
		in.SleepGoalState.LastAutoUpdateAt = msToTime(r.SleepLastAutoUpdateAt)
	}
	if r.NowMs > 0 {
		in.Now = time.UnixMilli(r.NowMs)
	}
	return in, nil
}

func msToTime(ms int64) *time.Time {
	if ms <= 0 {
		return nil
	}
	t := time.UnixMilli(ms)
	return &t
}
