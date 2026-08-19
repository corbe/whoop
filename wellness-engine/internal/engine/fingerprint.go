// Canonical input fingerprint (STAGE 14 §4 / STAGE 15.9).
//
// Deterministic identity of the physiological + goal-state input to a
// calculation. Same semantic input → same fingerprint; different relevant
// input → different fingerprint. Independent of slice/row ordering (sorted
// where order is not semantic), map order and JSON formatting.
//
// PARTICIPATES: all fields of Input that influence the bundle output —
// segments (sorted), HRV samples, battery samples (sorted), daily HRV
// averages (ORDERED — chronological semantics), instant HRV pairs
// (interleaved to keep sample↔timestamp association), sleep/fatigue
// histories (ordered), RHR/SpO2 inputs, steps records (sorted), session
// kcal, goal inputs (current goal, samples, priors, bed/target, and the
// cooldown/override timestamps — they gate F-08/F-09 and therefore the
// effective goals).
//
// EXCLUDED: PersonID (identity, not input), Date/Location (day boundary
// semantics live in the row: logical_day + timezone columns), Now (runtime
// wall-clock — the calculation is deterministic in (Now − timestamps); the
// timestamps themselves participate, so shifting Now+timestamps together
// yields a different fingerprint but identical math — documented as an
// accepted false-negative for idempotency, never a correctness issue).
package engine

import (
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/night"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/activity"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/versioning"
)

type fingerprintInput struct {
	Segments             []domain.Segment // sorted by (StartMs, EndMs)
	HRVMs                []float64
	Battery              []night.BatterySample // sorted by TimestampMs
	DailyHrvAverages     []float64             // ordered (chronological)
	InstantPairs         [][2]float64          // (sample, timestamp) interleaved
	SleepHistoryScores   []int
	FatigueHistoryScores []int
	LastNightRhr         *float64
	RhrBaseline          *float64
	Spo2Tonight          *float64
	Spo2Baseline         *float64
	Steps                []activity.StepsRecord // sorted by (Timestamp, Device, Value)
	SessionKcal          int
	GoalSteps            int
	GoalStepSamples      []int
	GoalPriorSteps       int
	GoalMaxDailySteps    int
	GoalState            goalStateFP
	BedtimeMinutes       []int
	DurationMinutes      []int
	SleepGoalState       sleepGoalStateFP
}

type goalStateFP struct {
	CurrentGoal      int
	LastAutoUpdateAt *time.Time
	ManualOverrideAt *time.Time
}

type sleepGoalStateFP struct {
	CurrentBedTime     *int
	CurrentSleepTarget *int
	LastAutoUpdateAt   *time.Time
	ManualOverrideAt   *time.Time
}

// Fingerprint returns "sha256:<hex>" over the canonical input serialization.
func (in Input) Fingerprint() (string, error) {
	fp := fingerprintInput{
		HRVMs:                in.HRVMs,
		DailyHrvAverages:     in.DailyHrvAverages,
		SleepHistoryScores:   in.SleepHistoryScores,
		FatigueHistoryScores: in.FatigueHistoryScores,
		LastNightRhr:         in.LastNightRhr,
		RhrBaseline:          in.RhrBaseline,
		Spo2Tonight:          in.Spo2Tonight,
		Spo2Baseline:         in.Spo2Baseline,
		SessionKcal:          in.SessionKcal,
		GoalSteps:            in.GoalSteps,
		GoalStepSamples:      in.GoalStepSamples,
		GoalPriorSteps:       in.GoalPriorSteps,
		GoalMaxDailySteps:    in.GoalMaxDailySteps,
		GoalState: goalStateFP{
			CurrentGoal:      in.GoalState.CurrentGoal,
			LastAutoUpdateAt: in.GoalState.LastAutoUpdateAt,
			ManualOverrideAt: in.GoalState.ManualOverrideAt,
		},
		BedtimeMinutes:  in.BedtimeMinutes,
		DurationMinutes: in.DurationMinutes,
		SleepGoalState: sleepGoalStateFP{
			CurrentBedTime:     in.SleepGoalState.CurrentBedTime,
			CurrentSleepTarget: in.SleepGoalState.CurrentSleepTarget,
			LastAutoUpdateAt:   in.SleepGoalState.LastAutoUpdateAt,
			ManualOverrideAt:   in.SleepGoalState.ManualOverrideAt,
		},
	}

	// order-independent: sort where order is not semantic
	fp.Segments = append([]domain.Segment(nil), in.Segments...)
	sort.Slice(fp.Segments, func(i, j int) bool {
		if fp.Segments[i].StartMs != fp.Segments[j].StartMs {
			return fp.Segments[i].StartMs < fp.Segments[j].StartMs
		}
		return fp.Segments[i].EndMs < fp.Segments[j].EndMs
	})
	fp.Battery = append([]night.BatterySample(nil), in.Battery...)
	sort.Slice(fp.Battery, func(i, j int) bool { return fp.Battery[i].TimestampMs < fp.Battery[j].TimestampMs })
	fp.Steps = append([]activity.StepsRecord(nil), in.StepsRecords...)
	sort.Slice(fp.Steps, func(i, j int) bool {
		if fp.Steps[i].Timestamp != fp.Steps[j].Timestamp {
			return fp.Steps[i].Timestamp < fp.Steps[j].Timestamp
		}
		if fp.Steps[i].Device != fp.Steps[j].Device {
			return fp.Steps[i].Device < fp.Steps[j].Device
		}
		return fp.Steps[i].Value < fp.Steps[j].Value
	})
	// keep sample↔timestamp association
	fp.InstantPairs = make([][2]float64, len(in.InstantHrvSamples))
	for i := range fp.InstantPairs {
		fp.InstantPairs[i] = [2]float64{in.InstantHrvSamples[i], float64(in.InstantHrvTimestamps[i])}
	}

	canon, err := versioning.CanonicalString(fp)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(canon))
	return "sha256:" + hex.EncodeToString(sum[:]), nil
}
