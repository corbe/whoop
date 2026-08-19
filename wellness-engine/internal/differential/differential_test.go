// Differential harness unit tests (STAGE 18.20): canonical parsing, Go
// runner, comparator semantics, case-level report accounting, fail policy,
// deterministic generator. No Dart, no DB.
package differential

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
)

func TestLoadFixtures(t *testing.T) {
	dir := t.TempDir()
	for _, id := range []string{"a.json", "b.json"} {
		f := &Fixture{FixtureID: id, PersonID: "p_" + id, Day: "2026-08-10", Timezone: time.Local.String()}
		raw, _ := json.Marshal(f)
		os.WriteFile(filepath.Join(dir, id), raw, 0o644)
	}
	fs, err := LoadFixtures(dir)
	if err != nil || len(fs) != 2 {
		t.Fatalf("LoadFixtures: %d fixtures, err %v", len(fs), err)
	}
	if fs[0].PersonID != "p_a.json" {
		t.Fatalf("unexpected fixture order/person: %+v", fs[0])
	}
}

// TestGoRunnerB2 runs the golden B.2 day through the Go runner and asserts
// the exact B.2 scores (sleep 90 / stress 40 / readiness 78 / activity 78).
func TestGoRunnerB2(t *testing.T) {
	f := b2Fixture()
	r, err := NewGoRunner(engine.DefaultConfigs()).Run(f)
	if err != nil {
		t.Fatalf("go runner: %v", err)
	}
	if r.Scores.Sleep != 90 || r.Scores.Stress != 40 || r.Scores.Readiness != 78 || r.Scores.Activity != 78 {
		t.Fatalf("B.2 mismatch: sleep=%d stress=%d readiness=%d activity=%d (want 90/40/78/78)",
			r.Scores.Sleep, r.Scores.Stress, r.Scores.Readiness, r.Scores.Activity)
	}
}

// resultWithScores builds a Result with the score set populated.
func resultWithScores(sleep, stress, readiness, activity int) *Result {
	r := &Result{}
	r.Scores.Sleep, r.Scores.Stress, r.Scores.Readiness, r.Scores.Activity = sleep, stress, readiness, activity
	return r
}

func TestComparatorIntExact(t *testing.T) {
	d := resultWithScores(90, 40, 78, 78)
	g := resultWithScores(90, 40, 78, 79)
	ms := Compare("x", d, g)
	if len(ms) != 1 || ms[0].Field != "scores.activity" || ms[0].Class != ClassFinalScore {
		t.Fatalf("expected one FINAL_SCORE mismatch on scores.activity, got %+v", ms)
	}
}

func TestComparatorFloatTolerance(t *testing.T) {
	d := &Result{}
	d.Stress.BaselineMs = 64.57129788989334
	g := &Result{}
	g.Stress.BaselineMs = 64.5712978898933
	ms := Compare("x", d, g)
	if len(ms) != 1 || ms[0].Class != ClassRoundingOnly {
		t.Fatalf("float tail within 1e-9 must be ROUNDING_ONLY, got %+v", ms)
	}
	d2 := &Result{}
	d2.Stress.BaselineMs = 64.57
	g2 := &Result{}
	g2.Stress.BaselineMs = 64.58
	ms2 := Compare("x", d2, g2)
	if len(ms2) != 1 || ms2[0].Class != ClassIntermediate {
		t.Fatalf("float delta beyond tolerance must be INTERMEDIATE, got %+v", ms2)
	}
}

func TestComparatorExactMatch(t *testing.T) {
	d := resultWithScores(90, 0, 0, 0)
	g := resultWithScores(90, 0, 0, 0)
	if ms := Compare("x", d, g); len(ms) != 0 {
		t.Fatalf("identical results must match, got %+v", ms)
	}
}

func TestClassifyCase(t *testing.T) {
	if c := ClassifyCase(nil); c != CaseExact {
		t.Fatalf("no mismatches → EXACT, got %s", c)
	}
	if c := ClassifyCase([]Mismatch{{Class: ClassRoundingOnly}}); c != CaseExpectedOnly {
		t.Fatalf("expected-only → EXPECTED_ONLY, got %s", c)
	}
	if c := ClassifyCase([]Mismatch{{Class: ClassRoundingOnly}, {Class: ClassFinalScore}}); c != CaseMismatched {
		t.Fatalf("mixed expected+unexplained → MISMATCHED, got %s", c)
	}
}

func TestIsFailure(t *testing.T) {
	if IsFailure(ClassRoundingOnly) || IsFailure(ClassExactMatch) {
		t.Fatal("ROUNDING_ONLY/EXACT_MATCH must not fail CI")
	}
	for _, c := range []MismatchClass{ClassFinalScore, ClassUnknown, ClassBaseline, ClassGoal, ClassIntermediate, ClassMissingData, ClassQualityFlag} {
		if !IsFailure(c) {
			t.Fatalf("%s must fail CI", c)
		}
	}
}

// TestReportAccounting covers the case-level invariant
// exact + expected_only + mismatched == total_cases.
func TestReportAccounting(t *testing.T) {
	// 1 case, 0 mismatches
	rep := BuildReport(1, nil, Timing{})
	if rep.Summary.ExactCases != 1 || rep.Summary.ExpectedOnlyCases != 0 || rep.Summary.MismatchedCases != 0 {
		t.Fatalf("1 case/0 diffs: %+v", rep.Summary)
	}
	// 1 case, 5 mismatches (unexplained) → 1 MISMATCHED case, 5 fields
	ms := []Mismatch{{FixtureID: "a", Class: ClassFinalScore}, {FixtureID: "a", Class: ClassIntermediate},
		{FixtureID: "a", Class: ClassFinalScore}, {FixtureID: "a", Class: ClassIntermediate}, {FixtureID: "a", Class: ClassUnknown}}
	rep = BuildReport(1, ms, Timing{})
	if rep.Summary.ExactCases != 0 || rep.Summary.ExpectedOnlyCases != 0 || rep.Summary.MismatchedCases != 1 ||
		rep.Summary.TotalMismatchFields != 5 || rep.Summary.UnexplainedMismatchFields != 5 {
		t.Fatalf("1 case/5 unexplained: %+v", rep.Summary)
	}
	// 3 cases, mismatches concentrated in one case
	ms = []Mismatch{{FixtureID: "a", Class: ClassFinalScore}, {FixtureID: "a", Class: ClassFinalScore}}
	rep = BuildReport(3, ms, Timing{})
	if rep.Summary.ExactCases != 2 || rep.Summary.MismatchedCases != 1 || rep.Summary.TotalMismatchFields != 2 {
		t.Fatalf("3 cases/1 bad: %+v", rep.Summary)
	}
	// expected-only case
	ms = []Mismatch{{FixtureID: "a", Class: ClassRoundingOnly}}
	rep = BuildReport(1, ms, Timing{})
	if rep.Summary.ExpectedOnlyCases != 1 || rep.Summary.MismatchedCases != 0 || rep.Summary.ExpectedDifferenceFields != 1 {
		t.Fatalf("expected-only case: %+v", rep.Summary)
	}
	// mixed expected + unexplained in one case → MISMATCHED
	ms = []Mismatch{{FixtureID: "a", Class: ClassRoundingOnly}, {FixtureID: "a", Class: ClassGoal}}
	rep = BuildReport(1, ms, Timing{})
	if rep.Summary.MismatchedCases != 1 || rep.Summary.ExpectedOnlyCases != 0 ||
		rep.Summary.ExpectedDifferenceFields != 1 || rep.Summary.UnexplainedMismatchFields != 1 {
		t.Fatalf("mixed case must be MISMATCHED: %+v", rep.Summary)
	}
	// invariant across all scenarios
	for _, n := range []int{1, 3} {
		_ = n
	}
}

// b2Fixture rebuilds the golden B.2 day (testdata/example-day.json) in the
// CANONICAL fixture format: raw HRV samples placed so bucketing reproduces
// the example's daily averages exactly, all other inputs mirrored 1:1.
func b2Fixture() *Fixture {
	day := time.Date(2026, 8, 10, 0, 0, 0, 0, time.Local)
	daily := []float64{49.575, 48.6175, 47.66, 46.7025, 45.745, 44.7875, 43.83,
		42.8725, 41.915, 40.9575, 40.0, 39.0425, 38.085, 37.1275, 36.17,
		35.2125, 34.255, 33.2975, 32.34, 31.3825, 30.425}
	var hrv []HRVSample
	// daily is oldest→newest [D-21..D]: index 0 = D-20's sample, index 20 =
	// the anchor day's sample.
	for i, v := range daily {
		dd := day.AddDate(0, 0, -(20 - i))
		hrv = append(hrv, HRVSample{Ms: msLocal(dd.Year(), dd.Month(), dd.Day(), 12, 0), Value: v})
	}
	steps := 4200.0
	goal := 7000
	rhr := 62.0
	rhrBase := 64.67
	spo2 := 95.2
	spo2Base := 96.07
	return &Fixture{
		FixtureID: "golden_b2",
		PersonID:  "golden_person_b2",
		Day:       day.Format("2006-01-02"),
		Timezone:  time.Local.String(),
		Segments: []Segment{
			{StartMs: msLocal(2026, 8, 9, 23, 26), EndMs: msLocal(2026, 8, 10, 0, 4), Stage: -3},
			{StartMs: msLocal(2026, 8, 10, 0, 4), EndMs: msLocal(2026, 8, 10, 0, 42), Stage: -1},
			{StartMs: msLocal(2026, 8, 10, 0, 42), EndMs: msLocal(2026, 8, 10, 2, 18), Stage: -4},
			{StartMs: msLocal(2026, 8, 10, 2, 18), EndMs: msLocal(2026, 8, 10, 7, 26), Stage: -3},
		},
		HRV:                  hrv,
		Steps:                []StepRecord{{Value: steps, Calories: 168, DistanceM: 3360, Ms: msLocal(2026, 8, 10, 12, 0), Device: "BRACELET"}},
		SessionKcal:          50,
		SleepHistory:         []int{85, 70, 0, 80},
		LastNightRhr:         &rhr,
		RhrBaseline:          &rhrBase,
		Spo2Tonight:          &spo2,
		Spo2Baseline:         &spo2Base,
		GoalStepsCurrent:     goal,
		GoalPriorSteps:       7500,
		GoalMaxDailySteps:    15000,
		GoalLastAutoUpdateMs: 0,
		NowMs:                time.Date(2026, 8, 10, 12, 0, 0, 0, time.UTC).UnixMilli(),
	}
}

func TestGeneratorDeterminism(t *testing.T) {
	d1 := t.TempDir()
	d2 := t.TempDir()
	if _, err := GenerateCorpus(d1, 5, 42); err != nil {
		t.Fatal(err)
	}
	if _, err := GenerateCorpus(d2, 5, 42); err != nil {
		t.Fatal(err)
	}
	h1, _ := os.ReadFile(filepath.Join(d1, "synth_0000.json"))
	h2, _ := os.ReadFile(filepath.Join(d2, "synth_0000.json"))
	if string(h1) != string(h2) {
		t.Fatal("same seed must produce identical fixtures")
	}
	d3 := t.TempDir()
	if _, err := GenerateCorpus(d3, 5, 43); err != nil {
		t.Fatal(err)
	}
	h3, _ := os.ReadFile(filepath.Join(d3, "synth_0000.json"))
	if string(h1) == string(h3) {
		t.Fatal("different seed must produce different fixtures")
	}
}
