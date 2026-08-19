// Comparator + differential report (STAGE 18.6/18.7/18.13/18.14).
//
// Field policy:
//   - ints, bools, strings (categorical/status): EXACT equality
//   - floats (baseline values, stress baseline_ms, instant_hrv_ms): abs
//     tolerance 1e-9 — both sides run the same IEEE754 ops in the same
//     order over the same values, so anything larger is a real divergence
//   - lists: none in the normalized result (all fields are scalars)
//
// Every field in the normalized Result is COMPARABLE; metadata that only
// one implementation has is deliberately not emitted, so no
// EXPECTED_IMPLEMENTATION_METADATA whitelist is needed.
package differential

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// FloatTolerance is the documented float comparison bound (1e-9 abs).
const FloatTolerance = 1e-9

// MismatchClass classifies every difference.
type MismatchClass string

const (
	ClassExactMatch   MismatchClass = "EXACT_MATCH"
	ClassRoundingOnly MismatchClass = "ROUNDING_ONLY"
	ClassBaseline     MismatchClass = "BASELINE_DIFFERENCE"
	ClassGoal         MismatchClass = "GOAL_DIFFERENCE"
	ClassIntermediate MismatchClass = "INTERMEDIATE_DIFFERENCE"
	ClassFinalScore   MismatchClass = "FINAL_SCORE_DIFFERENCE"
	ClassMissingData  MismatchClass = "MISSING_DATA_DIFFERENCE"
	ClassQualityFlag  MismatchClass = "QUALITY_FLAG_DIFFERENCE"
	ClassUnknown      MismatchClass = "UNKNOWN"
)

// Mismatch is one field-level difference.
type Mismatch struct {
	FixtureID string        `json:"fixture_id"`
	Field     string        `json:"field"`
	DartValue any           `json:"dart_value"`
	GoValue   any           `json:"go_value"`
	Delta     float64       `json:"delta,omitempty"`
	Class     MismatchClass `json:"class"`
}

// Summary is the concise report headline.
type Summary struct {
	TotalCases int `json:"total_cases"`
	// ExactCases: cases with ZERO mismatches of any class.
	ExactCases int `json:"exact_cases"`
	// ExpectedOnlyCases: cases whose ONLY mismatches are expected
	// (ROUNDING_ONLY / whitelisted metadata).
	ExpectedOnlyCases int `json:"expected_only_cases"`
	// MismatchedCases: cases with >= 1 unexplained mismatch.
	MismatchedCases int `json:"mismatched_cases"`
	// TotalMismatchFields: all compared-field differences (any class).
	TotalMismatchFields int `json:"total_mismatch_fields"`
	// ExpectedDifferenceFields: expected-class field differences.
	ExpectedDifferenceFields int `json:"expected_difference_fields"`
	// UnexplainedMismatchFields: failure-class field differences.
	UnexplainedMismatchFields int            `json:"unexplained_mismatch_fields"`
	MaxScoreDelta             int            `json:"max_score_delta"`
	MismatchByClass           map[string]int `json:"mismatch_by_class"`
	DurationMs                int64          `json:"duration_ms"`
	Timing                    Timing         `json:"timing"`
}

// CaseClassification is the per-case verdict (EXACT / EXPECTED_ONLY /
// MISMATCHED). The invariant
// exact + expected_only + mismatched == total_cases always holds.
type CaseClassification string

const (
	CaseExact        CaseClassification = "EXACT"
	CaseExpectedOnly CaseClassification = "EXPECTED_ONLY"
	CaseMismatched   CaseClassification = "MISMATCHED"
)

// ClassifyCase buckets one case's mismatches into a case-level verdict.
func ClassifyCase(ms []Mismatch) CaseClassification {
	hasUnexplained := false
	for _, m := range ms {
		if IsFailure(m.Class) {
			hasUnexplained = true
			break
		}
	}
	if len(ms) == 0 {
		return CaseExact
	}
	if hasUnexplained {
		return CaseMismatched
	}
	return CaseExpectedOnly
}

// Timing records harness execution times (informational only).
type Timing struct {
	DartMs    int64 `json:"dart_ms"`
	GoMs      int64 `json:"go_ms"`
	CompareMs int64 `json:"compare_ms"`
}

// Report is the full machine-readable differential output.
type Report struct {
	GeneratedAt time.Time  `json:"generated_at"`
	Summary     Summary    `json:"summary"`
	Mismatches  []Mismatch `json:"mismatches"`
}

// Compare compares one Dart result with one Go result.
func Compare(fixtureID string, dart, goRes *Result) []Mismatch {
	var out []Mismatch
	check := func(field string, dv, gv any) {
		switch d := dv.(type) {
		case float64:
			g, ok := gv.(float64)
			if !ok {
				out = append(out, Mismatch{FixtureID: fixtureID, Field: field, DartValue: dv, GoValue: gv, Class: ClassUnknown})
				return
			}
			delta := math.Abs(d - g)
			if delta == 0 {
				return
			}
			class := ClassRoundingOnly
			if delta > FloatTolerance {
				class = classOf(field)
			}
			out = append(out, Mismatch{FixtureID: fixtureID, Field: field, DartValue: dv, GoValue: gv, Delta: delta, Class: class})
		default:
			if fmt.Sprintf("%v", dv) != fmt.Sprintf("%v", gv) {
				out = append(out, Mismatch{FixtureID: fixtureID, Field: field, DartValue: dv, GoValue: gv, Class: classOf(field)})
			}
		}
	}

	check("scores.sleep", dart.Scores.Sleep, goRes.Scores.Sleep)
	check("scores.stress", dart.Scores.Stress, goRes.Scores.Stress)
	check("scores.readiness", dart.Scores.Readiness, goRes.Scores.Readiness)
	check("scores.activity", dart.Scores.Activity, goRes.Scores.Activity)
	check("sleep.score", dart.Sleep.Score, goRes.Sleep.Score)
	check("sleep.msg1", dart.Sleep.Msg1, goRes.Sleep.Msg1)
	check("sleep.msg2", dart.Sleep.Msg2, goRes.Sleep.Msg2)
	check("sleep.msg3", dart.Sleep.Msg3, goRes.Sleep.Msg3)
	check("sleep.battery_depleted", dart.Sleep.Battery, goRes.Sleep.Battery)
	check("stress.score", dart.Stress.Score, goRes.Stress.Score)
	check("stress.down_count", dart.Stress.DownCount, goRes.Stress.DownCount)
	check("stress.baseline_ms", dart.Stress.BaselineMs, goRes.Stress.BaselineMs)
	check("stress.instant_hrv_ms", dart.Stress.InstantHrvMs, goRes.Stress.InstantHrvMs)
	check("readiness.score", dart.Readiness.Score, goRes.Readiness.Score)
	check("readiness.sleep_component", dart.Readiness.SleepComponent, goRes.Readiness.SleepComponent)
	check("readiness.recovery_component", dart.Readiness.RecoveryComponent, goRes.Readiness.RecoveryComponent)
	check("readiness.rhr_component", ptrVal(dart.Readiness.RhrComponent), ptrVal(goRes.Readiness.RhrComponent))
	check("readiness.spo2_component", ptrVal(dart.Readiness.Spo2Component), ptrVal(goRes.Readiness.Spo2Component))
	check("readiness.fatigue_component", ptrVal(dart.Readiness.FatigueComponent), ptrVal(goRes.Readiness.FatigueComponent))
	check("activity.score", dart.Activity.Score, goRes.Activity.Score)
	check("activity.day_target", dart.Activity.DayTarget, goRes.Activity.DayTarget)
	check("activity.zone_start", dart.Activity.ZoneStart, goRes.Activity.ZoneStart)
	check("activity.zone_end", dart.Activity.ZoneEnd, goRes.Activity.ZoneEnd)
	check("activity.goal_steps", dart.Activity.GoalSteps, goRes.Activity.GoalSteps)
	check("activity.goal_kcal", dart.Activity.GoalKcal, goRes.Activity.GoalKcal)
	check("activity.total_kcal", dart.Activity.TotalKcal, goRes.Activity.TotalKcal)
	check("goals.steps_updated", dart.Goals.StepsUpdated, goRes.Goals.StepsUpdated)
	check("goals.new_steps_goal", ptrVal(dart.Goals.NewStepsGoal), ptrVal(goRes.Goals.NewStepsGoal))
	check("goals.sleep_updated", dart.Goals.SleepUpdated, goRes.Goals.SleepUpdated)
	check("goals.new_bed_time", ptrVal(dart.Goals.NewBedTime), ptrVal(goRes.Goals.NewBedTime))
	check("goals.new_sleep_target", ptrVal(dart.Goals.NewSleepTarget), ptrVal(goRes.Goals.NewSleepTarget))
	check("baselines.steps_value", dart.Baselines.StepsValue, goRes.Baselines.StepsValue)
	check("baselines.steps_count", dart.Baselines.StepsCount, goRes.Baselines.StepsCount)
	check("baselines.steps_confidence", dart.Baselines.StepsConfidence, goRes.Baselines.StepsConfidence)
	check("baselines.bed_time_minutes", dart.Baselines.BedTime, goRes.Baselines.BedTime)
	check("baselines.sleep_target_minutes", dart.Baselines.SleepTarget, goRes.Baselines.SleepTarget)
	check("baselines.sleep_count", dart.Baselines.SleepCount, goRes.Baselines.SleepCount)
	check("baselines.sleep_confidence", dart.Baselines.SleepConfidence, goRes.Baselines.SleepConfidence)
	return out
}

// classOf maps a field path to its mismatch class.
func classOf(field string) MismatchClass {
	switch {
	case field == "scores.sleep" || field == "scores.stress" ||
		field == "scores.readiness" || field == "scores.activity" ||
		field == "sleep.score" || field == "stress.score" ||
		field == "readiness.score" || field == "activity.score":
		return ClassFinalScore
	case field == "readiness.sleep_component" || field == "readiness.recovery_component" ||
		field == "readiness.rhr_component" || field == "readiness.spo2_component" ||
		field == "readiness.fatigue_component" ||
		field == "activity.day_target" || field == "activity.zone_start" ||
		field == "activity.zone_end" || field == "activity.goal_steps" ||
		field == "activity.goal_kcal" || field == "activity.total_kcal" ||
		field == "stress.down_count" || field == "stress.baseline_ms" ||
		field == "stress.instant_hrv_ms" || field == "sleep.msg1" ||
		field == "sleep.msg2" || field == "sleep.msg3":
		return ClassIntermediate
	case field == "goals.steps_updated" || field == "goals.new_steps_goal" ||
		field == "goals.sleep_updated" || field == "goals.new_bed_time" ||
		field == "goals.new_sleep_target":
		return ClassGoal
	case field == "baselines.steps_value" || field == "baselines.steps_count" ||
		field == "baselines.steps_confidence" || field == "baselines.bed_time_minutes" ||
		field == "baselines.sleep_target_minutes" || field == "baselines.sleep_count" ||
		field == "baselines.sleep_confidence":
		return ClassBaseline
	case field == "sleep.battery_depleted":
		return ClassQualityFlag
	default:
		return ClassUnknown
	}
}

// IsFailure reports whether a mismatch class fails the CI policy
// (STAGE 18.14): everything except ROUNDING_ONLY (and EXACT_MATCH, which
// never appears in Mismatch).
func IsFailure(c MismatchClass) bool {
	switch c {
	case ClassExactMatch, ClassRoundingOnly:
		return false
	default:
		return true
	}
}

// BuildReport aggregates mismatches into a report + summary with CASE-LEVEL
// accounting (STAGE 18.6/18.13): exact/expected-only/mismatched cases sum to
// total_cases; fields are reported separately.
func BuildReport(cases int, mismatches []Mismatch, timing Timing) *Report {
	byClass := map[string]int{}
	maxScoreDelta := 0
	expectedFields, unexplainedFields := 0, 0

	byCase := map[string][]Mismatch{}
	for _, m := range mismatches {
		byClass[string(m.Class)]++
		if IsFailure(m.Class) {
			unexplainedFields++
		} else {
			expectedFields++
		}
		byCase[m.FixtureID] = append(byCase[m.FixtureID], m)
		if m.Class == ClassFinalScore || m.Class == ClassIntermediate {
			// deltas only meaningful on numeric values
			if d, ok := toFloat(m.DartValue); ok {
				if g, ok2 := toFloat(m.GoValue); ok2 {
					if int(math.Abs(d-g)) > maxScoreDelta {
						maxScoreDelta = int(math.Abs(d - g))
					}
				}
			}
		}
	}

	exactCases, expectedOnlyCases, mismatchedCases := 0, 0, 0
	for _, ms := range byCase {
		switch ClassifyCase(ms) {
		case CaseExact:
			exactCases++
		case CaseExpectedOnly:
			expectedOnlyCases++
		case CaseMismatched:
			mismatchedCases++
		}
	}
	// cases with no mismatches at all are exact
	exactCases += cases - len(byCase)

	return &Report{
		GeneratedAt: time.Now().UTC(),
		Summary: Summary{
			TotalCases:                cases,
			ExactCases:                exactCases,
			ExpectedOnlyCases:         expectedOnlyCases,
			MismatchedCases:           mismatchedCases,
			TotalMismatchFields:       len(mismatches),
			ExpectedDifferenceFields:  expectedFields,
			UnexplainedMismatchFields: unexplainedFields,
			MaxScoreDelta:             maxScoreDelta,
			MismatchByClass:           byClass,
			Timing:                    timing,
		},
		Mismatches: mismatches,
	}
}

func toFloat(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case int:
		return float64(x), true
	case json.Number:
		f, err := x.Float64()
		return f, err == nil
	default:
		return 0, false
	}
}

// WriteReport persists differential-report.json + a human summary.
func WriteReport(dir string, rep *Report) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(rep, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "differential-report.json"), raw, 0o644); err != nil {
		return err
	}
	// concise summary
	lines := []string{
		fmt.Sprintf("TOTAL CASES: %d", rep.Summary.TotalCases),
		fmt.Sprintf("EXACT CASES: %d", rep.Summary.ExactCases),
		fmt.Sprintf("EXPECTED-ONLY CASES: %d", rep.Summary.ExpectedOnlyCases),
		fmt.Sprintf("MISMATCHED CASES: %d", rep.Summary.MismatchedCases),
		fmt.Sprintf("TOTAL MISMATCH FIELDS: %d", rep.Summary.TotalMismatchFields),
		fmt.Sprintf("EXPECTED FIELDS: %d", rep.Summary.ExpectedDifferenceFields),
		fmt.Sprintf("UNEXPLAINED FIELDS: %d", rep.Summary.UnexplainedMismatchFields),
		fmt.Sprintf("MAX SCORE DELTA: %d", rep.Summary.MaxScoreDelta),
	}
	keys := make([]string, 0, len(rep.Summary.MismatchByClass))
	for k := range rep.Summary.MismatchByClass {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		lines = append(lines, fmt.Sprintf("  %s: %d", k, rep.Summary.MismatchByClass[k]))
	}
	return os.WriteFile(filepath.Join(dir, "differential-summary.txt"), []byte(joinLines(lines)), 0o644)
}

func joinLines(lines []string) string {
	out := ""
	for _, l := range lines {
		out += l + "\n"
	}
	return out
}

func ptrVal[T any](p *T) any {
	if p == nil {
		return nil
	}
	return *p
}
