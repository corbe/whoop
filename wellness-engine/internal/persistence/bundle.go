// Bundle projection — converts an engine.CalculationBundle into the
// repository persistence shape (STAGE 15.13). No DB types leak into the
// engine; this package sits between them.
package persistence

import (
	"encoding/json"
	"fmt"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/repository"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/versioning"
)

// ProjectBundle builds the repository Input + Bundle from a calculated day.
func ProjectBundle(in engine.Input, b *engine.CalculationBundle) (repository.Input, repository.Bundle, error) {
	fp, err := in.Fingerprint()
	if err != nil {
		return repository.Input{}, repository.Bundle{}, fmt.Errorf("fingerprint: %w", err)
	}
	rin := repository.Input{
		PersonID:    in.PersonID,
		Day:         in.Date,
		Timezone:    in.Location.String(),
		Fingerprint: fp,
	}

	quality, err := json.Marshal(map[string]any{
		"warnings": b.Quality.Warnings,
		"missing":  b.Quality.Missing,
	})
	if err != nil {
		return repository.Input{}, repository.Bundle{}, fmt.Errorf("quality: %w", err)
	}

	// scores from the explanations (exact typed payloads — STAGE 15.6)
	scores := make([]repository.Score, 0, len(b.Explanations))
	for key, ex := range b.Explanations {
		payload, err := json.Marshal(ex)
		if err != nil {
			return repository.Input{}, repository.Bundle{}, fmt.Errorf("explanation %s: %w", key, err)
		}
		version := b.Metadata.FormulaVersions[key]
		scores = append(scores, repository.Score{
			PersonID:       in.PersonID,
			LogicalDay:     in.Date,
			FormulaKey:     string(key),
			FormulaVersion: version,
			ConfigHash:     b.Metadata.ConfigHash,
			Score:          ex.Score,
			Explanation:    payload,
		})
	}

	// goal changes — only when the run actually applied one
	var goals []repository.Goal
	if b.Goals.Steps.Updated && b.Goals.Steps.NewGoal != nil {
		goals = append(goals, repository.Goal{
			PersonID:   in.PersonID,
			GoalKey:    string(versioning.KeyGoalSteps),
			Value:      *b.Goals.Steps.NewGoal,
			Reason:     string(b.Goals.Steps.Reason),
			Source:     "auto",
			FormulaKey: string(versioning.KeyGoalSteps),
			ConfigHash: b.Metadata.ConfigHash,
			AppliedAt:  b.Metadata.CalculatedAt,
		})
	}
	if b.Goals.Sleep.Updated && b.Goals.Sleep.NewSleepTarget != nil {
		goals = append(goals, repository.Goal{
			PersonID:       in.PersonID,
			GoalKey:        string(versioning.KeyGoalSleep),
			Value:          *b.Goals.Sleep.NewSleepTarget,
			BedTimeMinutes: b.Goals.Sleep.NewBedTime,
			Reason:         string(b.Goals.Sleep.Reason),
			Source:         "auto",
			FormulaKey:     string(versioning.KeyGoalSleep),
			ConfigHash:     b.Metadata.ConfigHash,
			AppliedAt:      b.Metadata.CalculatedAt,
		})
	}

	// baseline snapshot — the reference values the run consumed (no raw
	// physiological streams duplicated; STAGE 15.8/15.19)
	metrics, err := json.Marshal(map[string]any{
		"rhr_baseline_bpm":  in.RhrBaseline,
		"spo2_baseline_pct": in.Spo2Baseline,
		"steps_goal": map[string]any{
			"value":        b.Goals.Steps.Baseline.Value,
			"sample_count": b.Goals.Steps.Baseline.SampleCount,
			"confidence":   b.Goals.Steps.Baseline.Confidence.String(),
		},
		"sleep_config": map[string]any{
			"bed_time_minutes": b.Goals.Sleep.BedTimeMinutes,
			"target_minutes":   b.Goals.Sleep.SleepTargetMinutes,
			"sample_count":     b.Goals.Sleep.SampleCount,
			"confidence":       b.Goals.Sleep.Confidence.String(),
		},
	})
	if err != nil {
		return repository.Input{}, repository.Bundle{}, fmt.Errorf("baseline metrics: %w", err)
	}
	baseline := &repository.BaselineSnapshot{
		PersonID:   in.PersonID,
		LogicalDay: in.Date,
		Metrics:    metrics,
	}

	versions := make(map[string]int, len(b.Metadata.FormulaVersions))
	for k, v := range b.Metadata.FormulaVersions {
		versions[string(k)] = v
	}

	rb := repository.Bundle{
		ConfigHash:      b.Metadata.ConfigHash,
		EngineVersion:   b.Metadata.EngineVersion,
		FormulaVersions: versions,
		CalculatedAt:    b.Metadata.CalculatedAt,
		QualityJSON:     quality,
		Scores:          scores,
		GoalChanges:     goals,
		Baseline:        baseline,
	}
	return rin, rb, nil
}
