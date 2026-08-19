// wellness-engine — deterministic daily wellness score calculator.
//
// Pure calculation core (Phase 7): no HTTP, no database, no device code.
// Reads a JSON day-input from a file or stdin and prints the JSON result.
//
// Example:
//
//	cat testdata/example-day.json | go run ./cmd/wellness-engine
//	go run ./cmd/wellness-engine -input testdata/example-day.json
//
// Output contract mirrors the audit's explanation shape (Phase 12): the
// score, the formula/version fields (v1 parity config) and components.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/goals"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/activity"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/versioning"
)

// inputJSON is the CLI wire format (synthetic day; see
// docs/wellness-input-contract.md for field semantics).
type inputJSON struct {
	PersonID             string      `json:"person_id"`
	Date                 string      `json:"date"`     // YYYY-MM-DD
	Timezone             string      `json:"timezone"` // IANA, e.g. America/Sao_Paulo
	Segments             []segJSON   `json:"segments"`
	DailyHrvAverages     []float64   `json:"daily_hrv_averages_ms"`
	SleepHistoryScores   []int       `json:"sleep_history_scores"`
	FatigueHistoryScores []int       `json:"fatigue_history_scores"`
	LastNightRhr         *float64    `json:"last_night_rhr_bpm"`
	RhrBaseline          *float64    `json:"rhr_baseline_bpm"`
	Spo2Tonight          *float64    `json:"spo2_tonight_pct"`
	Spo2Baseline         *float64    `json:"spo2_baseline_pct"`
	Steps                []stepsJSON `json:"steps"`
	SessionKcal          int         `json:"session_kcal"`
	GoalSteps            int         `json:"goal_steps"`

	// Goal auto-update inputs (F-08/F-09; optional)
	GoalStepSamples       []int `json:"goal_step_samples_d1_d30"`
	GoalPriorSteps        int   `json:"goal_prior_steps"`
	GoalMaxDailySteps     int   `json:"goal_max_daily_steps"`
	GoalLastAutoUpdateAt  int64 `json:"goal_last_auto_update_at_ms,omitempty"`
	GoalManualOverrideAt  int64 `json:"goal_manual_override_at_ms,omitempty"`
	GoalCurrentSteps      int   `json:"goal_current_steps"`
	BedtimeMinutes        []int `json:"bedtime_minutes_d1_d21"`
	DurationMinutes       []int `json:"duration_minutes_d1_d21"`
	SleepLastAutoUpdateAt int64 `json:"sleep_last_auto_update_at_ms,omitempty"`
	SleepManualOverrideAt int64 `json:"sleep_manual_override_at_ms,omitempty"`
	SleepCurrentBedTime   *int  `json:"sleep_current_bed_time_minutes"`
	SleepCurrentTarget    *int  `json:"sleep_current_target_minutes"`
	NowMs                 int64 `json:"now_ms,omitempty"`
}

type segJSON struct {
	StartMs int64 `json:"start_ms"`
	EndMs   int64 `json:"end_ms"`
	Stage   int   `json:"stage"` // canonical: 0,-1,-2,-3,-4
}

type stepsJSON struct {
	Value     float64 `json:"value"`
	Calories  float64 `json:"calories"`
	DistanceM float64 `json:"distance_m"`
	Timestamp int64   `json:"timestamp_ms"`
	Device    string  `json:"device"` // BRACELET|API|RING
}

type componentJSON struct {
	Key    string  `json:"key"`
	Value  int     `json:"value"`
	Weight float64 `json:"weight"`
	Raw    float64 `json:"raw_value,omitempty"`
	Base   float64 `json:"baseline_value,omitempty"`
}

type goalUpdateJSON struct {
	Updated     bool    `json:"updated"`
	NewGoal     *int    `json:"new_goal,omitempty"`
	BedTime     *int    `json:"bed_time_minutes,omitempty"` // sleep update only
	Target      *int    `json:"target_minutes,omitempty"`   // sleep update only
	Reason      string  `json:"reason"`
	Baseline    float64 `json:"baseline_value"`
	SampleCount int     `json:"sample_count"`
	Confidence  string  `json:"confidence"`
}

type resultJSON struct {
	PersonID        string          `json:"person_id"`
	Date            string          `json:"date"`
	Formula         string          `json:"formula"`
	Version         int             `json:"version"`
	ConfigHash      string          `json:"config_hash"`
	EngineVersion   string          `json:"engine_version"`
	Sleep           int             `json:"sleep"`
	Stress          int             `json:"stress"`
	Readiness       *int            `json:"readiness,omitempty"`
	Activity        int             `json:"activity"`
	DayTarget       int             `json:"day_target_percent"`
	ZoneStart       int             `json:"zone_start_percent"`
	ZoneEnd         int             `json:"zone_end_percent"`
	NightStart      int64           `json:"night_start_ms"`
	NightEnd        int64           `json:"night_end_ms"`
	SleepingMs      int64           `json:"sleeping_ms"`
	Components      []componentJSON `json:"components"`
	Codes           map[string]int  `json:"codes"`
	GoalStepsUpdate *goalUpdateJSON `json:"goal_steps_update,omitempty"`
	GoalSleepUpdate *goalUpdateJSON `json:"goal_sleep_update,omitempty"`
	Warnings        []string        `json:"warnings,omitempty"`
	Missing         []string        `json:"missing,omitempty"`
}

func main() {
	inputPath := flag.String("input", "", "path to day JSON (default: stdin)")
	explainMode := flag.Bool("explain", false, "detailed mode: goals + formula metadata + components + warnings")
	flag.Parse()

	var raw []byte
	var err error
	if *inputPath != "" {
		raw, err = os.ReadFile(*inputPath)
	} else {
		raw, err = io.ReadAll(os.Stdin)
	}
	if err != nil {
		fatal("read input: %v", err)
	}

	var in inputJSON
	if err := json.Unmarshal(raw, &in); err != nil {
		fatal("parse input: %v", err)
	}

	loc, err := time.LoadLocation(in.Timezone)
	if err != nil {
		fatal("timezone %q: %v", in.Timezone, err)
	}
	date, err := time.ParseInLocation("2006-01-02", in.Date, loc)
	if err != nil {
		fatal("date %q: %v", in.Date, err)
	}

	segments := make([]domain.Segment, len(in.Segments))
	for i, s := range in.Segments {
		segments[i] = domain.Segment{StartMs: s.StartMs, EndMs: s.EndMs, Stage: domain.Stage(s.Stage)}
	}
	steps := make([]activity.StepsRecord, len(in.Steps))
	for i, s := range in.Steps {
		steps[i] = activity.StepsRecord{
			Value:     s.Value,
			Calories:  s.Calories,
			DistanceM: s.DistanceM,
			Timestamp: s.Timestamp,
			Device:    domain.DeviceSource(s.Device),
		}
	}

	engineIn := engine.Input{
		PersonID:             in.PersonID,
		Date:                 date,
		Location:             loc,
		Segments:             segments,
		DailyHrvAverages:     in.DailyHrvAverages,
		SleepHistoryScores:   in.SleepHistoryScores,
		FatigueHistoryScores: in.FatigueHistoryScores,
		LastNightRhr:         in.LastNightRhr,
		RhrBaseline:          in.RhrBaseline,
		Spo2Tonight:          in.Spo2Tonight,
		Spo2Baseline:         in.Spo2Baseline,
		StepsRecords:         steps,
		SessionKcal:          in.SessionKcal,
		GoalSteps:            in.GoalSteps,
	}

	var res *engine.DayResult
	var bundle *engine.CalculationBundle
	if *explainMode {
		engineIn.GoalStepSamples = in.GoalStepSamples
		engineIn.GoalPriorSteps = in.GoalPriorSteps
		engineIn.GoalMaxDailySteps = in.GoalMaxDailySteps
		engineIn.GoalState = goals.StepsState{
			CurrentGoal:      in.GoalCurrentSteps,
			LastAutoUpdateAt: msPtr(in.GoalLastAutoUpdateAt),
			ManualOverrideAt: msPtr(in.GoalManualOverrideAt),
		}
		engineIn.BedtimeMinutes = in.BedtimeMinutes
		engineIn.DurationMinutes = in.DurationMinutes
		engineIn.SleepGoalState = goals.SleepState{
			CurrentBedTime:     in.SleepCurrentBedTime,
			CurrentSleepTarget: in.SleepCurrentTarget,
			LastAutoUpdateAt:   msPtr(in.SleepLastAutoUpdateAt),
			ManualOverrideAt:   msPtr(in.SleepManualOverrideAt),
		}
		if in.NowMs > 0 {
			engineIn.Now = time.UnixMilli(in.NowMs)
		}
		bundle, err = engine.CalculateDayDetailed(engineIn, engine.DefaultConfigs())
		if err != nil {
			fatal("calculate: %v", err)
		}
		res = &bundle.Scores
	} else {
		res, err = engine.CalculateDay(engineIn, engine.DefaultConfigs())
		if err != nil {
			fatal("calculate: %v", err)
		}
	}

	out := resultJSON{
		PersonID:      in.PersonID,
		Date:          in.Date,
		Formula:       "ritma-wellness",
		Version:       1, // parity config (ScoreCalibration.current)
		ConfigHash:    configHashOf(bundle),
		EngineVersion: engineVersionOf(bundle),
		Sleep:         res.Sleep.Score,
		Stress:        res.Stress.Score,
		Activity:      res.Activity.ActivityScore,
		DayTarget:     res.Activity.DayTargetPercent,
		ZoneStart:     res.Activity.ZoneStartPercent,
		ZoneEnd:       res.Activity.ZoneEndPercent,
		NightStart:    res.Night.StartMs,
		NightEnd:      res.Night.EndMs,
		SleepingMs:    res.Night.SleepingTimeMs(),
		Codes: map[string]int{
			"sleep_msg1":        res.Sleep.Msg1,
			"sleep_msg2":        res.Sleep.Msg2,
			"sleep_msg3":        res.Sleep.Msg3,
			"stress_down_count": res.Stress.DownCount,
		},
	}
	if res.Readiness != nil {
		v := res.Readiness.TotalScore
		out.Readiness = &v
		for _, c := range []struct {
			key    string
			value  int
			weight float64
		}{
			{"sleep", res.Readiness.SleepComponent, 0.35},
			{"recovery", res.Readiness.RecoveryComponent, 0.25},
		} {
			out.Components = append(out.Components, componentJSON{Key: c.key, Value: c.value, Weight: c.weight})
		}
		if res.Readiness.RhrComponent != nil {
			out.Components = append(out.Components, componentJSON{Key: "rhr", Value: *res.Readiness.RhrComponent, Weight: 0.15})
		}
		if res.Readiness.Spo2Component != nil {
			out.Components = append(out.Components, componentJSON{Key: "spo2", Value: *res.Readiness.Spo2Component, Weight: 0.10})
		}
		if res.Readiness.FatigueComponent != nil {
			out.Components = append(out.Components, componentJSON{Key: "fatigue", Value: *res.Readiness.FatigueComponent, Weight: 0.15})
		}
	}

	if bundle != nil {
		// goal updates
		out.GoalStepsUpdate = &goalUpdateJSON{
			Updated:     bundle.Goals.Steps.Updated,
			NewGoal:     bundle.Goals.Steps.NewGoal,
			Reason:      string(bundle.Goals.Steps.Reason),
			Baseline:    bundle.Goals.Steps.Baseline.Value,
			SampleCount: bundle.Goals.Steps.Baseline.SampleCount,
			Confidence:  bundle.Goals.Steps.Baseline.Confidence.String(),
		}
		out.GoalSleepUpdate = &goalUpdateJSON{
			Updated:     bundle.Goals.Sleep.Updated,
			BedTime:     bundle.Goals.Sleep.NewBedTime,
			Target:      bundle.Goals.Sleep.NewSleepTarget,
			Reason:      string(bundle.Goals.Sleep.Reason),
			Baseline:    float64(bundle.Goals.Sleep.BedTimeMinutes),
			SampleCount: bundle.Goals.Sleep.SampleCount,
			Confidence:  bundle.Goals.Sleep.Confidence.String(),
		}
		for _, w := range bundle.Quality.Warnings {
			out.Warnings = append(out.Warnings, w.Code)
		}
		for _, m := range bundle.Quality.Missing {
			out.Missing = append(out.Missing, string(m))
		}
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		fatal("encode result: %v", err)
	}
}

func configHashOf(b *engine.CalculationBundle) string {
	if b == nil {
		return ""
	}
	return b.Metadata.ConfigHash
}

func engineVersionOf(b *engine.CalculationBundle) string {
	if b == nil {
		return versioning.EngineVersion
	}
	return b.Metadata.EngineVersion
}

func msPtr(ms int64) *time.Time {
	if ms <= 0 {
		return nil
	}
	t := time.UnixMilli(ms)
	return &t
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "wellness-engine: "+format+"\n", args...)
	os.Exit(1)
}
