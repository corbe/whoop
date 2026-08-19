// Explanation engine — machine-readable answers to "why did this score
// equal X?".
//
// Built ONLY from calculations that actually exist in the ported formulas
// (docs/explanation-engine.md). No medical interpretation, no invented
// causal language. Every value is an intermediate that the formula really
// used; recomposition tests prove the explanation reproduces the final score
// exactly (including clamps and rounding steps).
package explain

import (
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/activity"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/readiness"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/sleep"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/stress"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/stats"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/versioning"
)

// MissingReason is a structured reason why a score is absent or reduced.
type MissingReason string

const (
	MissingSleepData       MissingReason = "SLEEP_DATA_UNAVAILABLE"         // empty night summary
	MissingBatteryDepleted MissingReason = "SLEEP_INVALID_BATTERY_DEPLETED" // band died mid-night
	MissingHrvDays         MissingReason = "INSUFFICIENT_HRV_DAYS"          // < minDaysRequired
	MissingInstantHrv      MissingReason = "INSTANT_HRV_UNAVAILABLE"        // no HRV in 15/60/180min windows
	ReadinessGatedNoStress MissingReason = "READINESS_GATED_NO_STRESS"      // stressScore <= 0
	ReadinessGatedNoSleep  MissingReason = "READINESS_GATED_NO_SLEEP"       // todaySleepScore <= 0
	MissingRhrBaseline     MissingReason = "RHR_BASELINE_UNAVAILABLE"       // no nightly RHR or baseline
	MissingSpo2Baseline    MissingReason = "SPO2_BASELINE_UNAVAILABLE"      // no nightly SpO2
	MissingFatigueData     MissingReason = "FATIGUE_DATA_UNAVAILABLE"       // no sleep scores in D-1..D-3
	NoActivityData         MissingReason = "ACTIVITY_DATA_UNAVAILABLE"      // no steps/sessions
)

// Warning is a pipeline quality flag (operational, NOT medical).
type Warning struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

const (
	WarnBatteryDepleted     = "WARN_BATTERY_DEPLETED"
	WarnNightDurationCapped = "WARN_NIGHT_DURATION_CAPPED"   // >16h truncated
	WarnDegenerateWindow    = "WARN_NIGHT_DEGENERATE_WINDOW" // start==end (nightEnd-clamped)
	WarnNoInstantHrv        = "WARN_INSTANT_HRV_UNAVAILABLE"
)

// Component is one scoring component (fields only filled when applicable).
type Component struct {
	Key string `json:"key"`
	// RawValue is the direct input (bpm, %, ms, kcal, ratio...).
	RawValue *float64 `json:"raw_value,omitempty"`
	// BaselineValue is the reference the raw value is compared against.
	BaselineValue *float64 `json:"baseline_value,omitempty"`
	// NormalizedValue is the 0-100 component score.
	NormalizedValue int `json:"normalized_value"`
	// Weight is the configured blend weight (0 for non-blend components).
	Weight float64 `json:"weight"`
	// Contribution is normalized*weight (pre-renormalization), the value the
	// weighted blend sums.
	Contribution float64 `json:"contribution"`
}

// Step is a linear transformation step in the score pipeline.
type Step struct {
	Name  string  `json:"name"`
	Value float64 `json:"value"`
}

// Explanation is the machine-readable output for one formula.
type Explanation struct {
	Score          int             `json:"score"`
	FormulaKey     versioning.Key  `json:"formula_key"`
	FormulaVersion int             `json:"formula_version"`
	ConfigHash     string          `json:"config_hash"`
	EngineVersion  string          `json:"engine_version"`
	CalculatedAt   time.Time       `json:"calculated_at"`
	Components     []Component     `json:"components,omitempty"`
	Steps          []Step          `json:"steps,omitempty"`
	Warnings       []Warning       `json:"warnings,omitempty"`
	Missing        []MissingReason `json:"missing,omitempty"`
}

// Meta bundles the metadata attached to every explanation.
type Meta struct {
	ConfigHash    string
	EngineVersion string
	CalculatedAt  time.Time
}

// ── Sleep ──────────────────────────────────────────────────────────────────

// Sleep builds the sleep explanation. Recomposition:
// score = clamp(100 − trunc(quality + bed + target), 0, 100).
func Sleep(res sleep.Result, night domain.NightSummary, bedTimeMinutes, sleepTargetMinutes int, m Meta) Explanation {
	ex := Explanation{
		Score:          res.Score,
		FormulaKey:     versioning.KeySleep,
		FormulaVersion: 1,
		ConfigHash:     m.ConfigHash,
		EngineVersion:  m.EngineVersion,
		CalculatedAt:   m.CalculatedAt,
	}
	if night.IsEmpty() {
		ex.Missing = append(ex.Missing, MissingSleepData)
		return ex
	}
	if res.BateriaZerada {
		ex.Missing = append(ex.Missing, MissingBatteryDepleted)
		ex.Warnings = append(ex.Warnings, Warning{WarnBatteryDepleted, "device battery below 3% before night end; sleep deemed incomplete (score 0)"})
		return ex
	}
	if night.DurationCapped {
		ex.Warnings = append(ex.Warnings, Warning{WarnNightDurationCapped, "night duration exceeded 16h and was capped"})
	}
	if night.DegenerateWindow {
		ex.Warnings = append(ex.Warnings, Warning{WarnDegenerateWindow, "night window is zero-width (segment clamped at night end); durations still counted"})
	}
	ex.Steps = []Step{
		{"bedtime_minutes_target", float64(bedTimeMinutes)},
		{"sleep_target_minutes", float64(sleepTargetMinutes)},
		{"actual_bedtime_minutes_of_day", float64(minuteOfDay(night.StartMs))},
		{"sleeping_minutes", float64(res.SleepingMs / 60000)},
		{"pct_rem", res.PctRem},
		{"pct_deep", res.PctDeep},
		{"pct_light", res.PctLight},
		{"bedtime_discount", res.BedTimeDiscount},
		{"duration_discount", res.TargetSleepDiscount},
		{"stage_quality_discount", res.QualityDiscount},
		{"total_discount_pre_truncation", res.TotalDiscount},
		{"total_discount_truncated", float64(stats.TruncInt(res.TotalDiscount))},
		{"score_pre_clamp", float64(100 - stats.TruncInt(res.TotalDiscount))},
	}
	ex.Components = []Component{
		{Key: "bedtime", RawValue: f(res.BedTimeDiscount), NormalizedValue: res.Msg1},
		{Key: "duration", RawValue: f(res.TargetSleepDiscount), NormalizedValue: res.Msg2},
		{Key: "stage_quality", RawValue: f(res.QualityDiscount), NormalizedValue: res.Msg3},
	}
	return ex
}

// ── Stress ─────────────────────────────────────────────────────────────────

// Stress builds the stress explanation. Recomposition:
// z = (ln(baseline) − ln(sanitized))/lnSd (clamped, or −0.4 at 2x);
// logistic = 1/(1+exp(−steepness(z−mid))); raw = 12 + 83*logistic (clamped);
// score = round(raw).clamp(0,100).
func Stress(res stress.TrendResult, m Meta) Explanation {
	ex := Explanation{
		Score:          res.Score,
		FormulaKey:     versioning.KeyStress,
		FormulaVersion: 1,
		ConfigHash:     m.ConfigHash,
		EngineVersion:  m.EngineVersion,
		CalculatedAt:   m.CalculatedAt,
	}
	if !res.Sufficient {
		ex.Missing = append(ex.Missing, MissingHrvDays)
		return ex
	}
	ex.Steps = []Step{
		{"baseline_ms", res.BaselineMs},
		{"baseline_ln_sd", res.BaselineLnSd},
		{"trend_ms_7d_weighted", res.TrendMs},
		{"observed_ms", res.ObservedMs},
		{"sanitized_ms", res.SanitizedMs},
		{"z", res.Z},
		{"score_pre_round", res.RawScore},
	}
	return ex
}

// ── Readiness ──────────────────────────────────────────────────────────────

// ReadinessInput carries the raw inputs for the readiness components.
type ReadinessInput struct {
	LastNightRhr *float64
	RhrBaseline  *float64
	Spo2Tonight  *float64
	Spo2Baseline *float64
	FatigueAvg   *int
}

// Readiness builds the readiness explanation from the breakdown and the raw
// inputs. Recomposition:
// blended = round(Σ normalized*weight / Σ weight);
// total = min(blended, cap-by-today-sleep) when capped.
func Readiness(b *readiness.Breakdown, in ReadinessInput, todaySleepScore int, m Meta) Explanation {
	ex := Explanation{
		Score:          b.TotalScore,
		FormulaKey:     versioning.KeyReadiness,
		FormulaVersion: 1,
		ConfigHash:     m.ConfigHash,
		EngineVersion:  m.EngineVersion,
		CalculatedAt:   m.CalculatedAt,
	}
	totalWeight := 0.0
	for _, c := range b.Components {
		ex.Components = append(ex.Components, Component{
			Key:             c.Key,
			NormalizedValue: c.Score,
			Weight:          c.Weight,
			Contribution:    float64(c.Score) * c.Weight,
		})
		totalWeight += c.Weight
	}
	// attach raw inputs where available
	for i := range ex.Components {
		switch ex.Components[i].Key {
		case "rhr":
			if in.LastNightRhr != nil {
				ex.Components[i].RawValue = in.LastNightRhr
			}
			if in.RhrBaseline != nil {
				ex.Components[i].BaselineValue = in.RhrBaseline
			}
		case "spo2":
			if in.Spo2Tonight != nil {
				ex.Components[i].RawValue = in.Spo2Tonight
			}
			if in.Spo2Baseline != nil {
				ex.Components[i].BaselineValue = in.Spo2Baseline
			}
		case "fatigue":
			if in.FatigueAvg != nil {
				ex.Components[i].RawValue = f(float64(*in.FatigueAvg))
			}
		case "sleep":
			ex.Components[i].RawValue = f(float64(b.SleepComponent))
		case "recovery":
			ex.Components[i].RawValue = f(float64(b.RecoveryComponent))
		}
	}
	ex.Steps = []Step{
		{"sleep_historical_avg", float64(b.SleepHistoricalAvg)},
		{"blend_weighted_sum", sumContributions(ex.Components)},
		{"blend_total_weight", totalWeight},
		{"blended_pre_round", sumContributions(ex.Components) / totalWeight},
		{"blended", float64(b.Blended)},
		{"today_sleep_score", float64(todaySleepScore)},
	}
	if b.CapApplied != nil {
		ex.Steps = append(ex.Steps, Step{"cap_applied", float64(*b.CapApplied)})
	}
	if in.LastNightRhr == nil || in.RhrBaseline == nil {
		ex.Missing = append(ex.Missing, MissingRhrBaseline)
	}
	if in.Spo2Tonight == nil {
		ex.Missing = append(ex.Missing, MissingSpo2Baseline)
	}
	if in.FatigueAvg == nil {
		ex.Missing = append(ex.Missing, MissingFatigueData)
	}
	return ex
}

// ── Activity ───────────────────────────────────────────────────────────────

// Activity builds the activity explanation. Recomposition:
// score = round(100 * totalKcal / goalKcal).clamp(0,100).
func Activity(res activity.DayResult, m Meta) Explanation {
	ex := Explanation{
		Score:          res.ActivityScore,
		FormulaKey:     versioning.KeyActivity,
		FormulaVersion: 1,
		ConfigHash:     m.ConfigHash,
		EngineVersion:  m.EngineVersion,
		CalculatedAt:   m.CalculatedAt,
	}
	ratio := 0.0
	if res.GoalKcal > 0 {
		ratio = float64(res.TotalKcal) / float64(res.GoalKcal)
	}
	ex.Components = []Component{
		{Key: "wearable_kcal", RawValue: f(float64(res.WearableDayKcal))},
		{Key: "session_kcal", RawValue: f(float64(res.SessionKcal))},
		{Key: "total_kcal", RawValue: f(float64(res.TotalKcal))},
		{Key: "goal_kcal", RawValue: f(float64(res.GoalKcal))},
		{Key: "goal_steps", RawValue: f(float64(res.GoalSteps))},
		{Key: "day_target_percent", RawValue: f(float64(res.DayTargetPercent))},
		{Key: "today_target_kcal", RawValue: f(float64(res.TodayTargetKcal))},
	}
	ex.Steps = []Step{
		{"kcal_ratio", ratio},
		{"score_pre_clamp", ratio * 100},
	}
	if res.TotalKcal <= 0 {
		ex.Missing = append(ex.Missing, NoActivityData)
	}
	return ex
}

func minuteOfDay(ms int64) float64 {
	t := time.UnixMilli(ms)
	return float64(t.Hour()*60 + t.Minute())
}

func f(v float64) *float64 { return &v }

func sumContributions(cs []Component) float64 {
	s := 0.0
	for _, c := range cs {
		s += c.Contribution
	}
	return s
}
