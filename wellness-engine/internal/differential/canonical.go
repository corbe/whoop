// Canonical differential fixture — one sanitized person-day, consumable by
// BOTH the Dart runner (test/diff_runner_test.dart) and the Go runner
// (STAGE 18.2). Same wire format family as the CLI/API day input; adds the
// fields the DART side needs to seed its real services (raw HR/SpO2/HRV
// samples with timestamps, goal state, demographics).
//
// Privacy: person_id is synthetic; no names/emails/tokens anywhere.
package differential

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Segment mirrors the canonical stage interval.
type Segment struct {
	StartMs int64 `json:"start_ms"`
	EndMs   int64 `json:"end_ms"`
	Stage   int8  `json:"stage"` // canonical: 0 wake, -1 rem, -2 nap, -3 light, -4 deep
}

// HRVSample is one raw HRV sample (ms).
type HRVSample struct {
	Ms    int64   `json:"ms"`
	Value float64 `json:"value"`
}

// BatterySample is one raw battery sample.
type BatterySample struct {
	Ms    int64   `json:"ms"`
	Value float64 `json:"value"`
}

// StepRecord is one wearable step counter record (cumulative daily value).
type StepRecord struct {
	Value     float64 `json:"value"`
	Calories  float64 `json:"calories,omitempty"`
	DistanceM float64 `json:"distance_m,omitempty"`
	Ms        int64   `json:"ms"`
	Device    string  `json:"device,omitempty"`
}

// HRSample is one raw heart-rate sample (bpm) — used only to derive the
// RHR/SpO2 baselines the Dart services compute from the DB.
type HRSample struct {
	Ms    int64   `json:"ms"`
	Value float64 `json:"value"`
}

// SpO2Sample is one raw SpO2 sample (%).
type SpO2Sample struct {
	Ms    int64   `json:"ms"`
	Value float64 `json:"value"`
}

// GoalNight is one canonical sleep night (segments) for the F-09 window.
type GoalNight struct {
	Date     string    `json:"date"` // YYYY-MM-DD of the night anchor
	Segments []Segment `json:"segments"`
}

// Fixture is the canonical differential input (STAGE 18.2).
type Fixture struct {
	FixtureID string `json:"fixture_id"`
	// PersonID is SYNTHETIC (generated) — never a real identifier.
	PersonID string `json:"person_id"`
	Day      string `json:"day"` // YYYY-MM-DD, device-local semantics
	// Timezone MUST equal the runner host's local zone (the Dart services
	// bucket by local time); the generator emits time.Local.String().
	Timezone string `json:"timezone"`

	Segments []Segment `json:"segments"` // anchor night

	// HRV samples spanning [D-21, D] local; the runners derive nightly avg
	// HRV, the stress daily averages AND instant HRV from this single list.
	HRV []HRVSample `json:"hrv"`

	Battery []BatterySample `json:"battery,omitempty"`

	// Steps for the anchor day (activity).
	Steps []StepRecord `json:"steps,omitempty"`
	// SessionKcal for the anchor day (activity).
	SessionKcal int `json:"session_kcal,omitempty"`

	// Expected sleep scores for D-1..D-4 (readiness history + fatigue) —
	// the generator derives them from BaselineNights[0..3] via the
	// golden-verified Go sleep formula; the Dart runner recomputes them.
	SleepHistory []int `json:"sleep_history"` // 4 entries, D-1..D-4 (0 = no data)
	// BaselineNights are the canonical segments for D-1..D-30 — the SINGLE
	// source the Dart runner seeds (RHR/SpO2 baselines need segments in all
	// 30 nights; F-09 reads D-1..D-21; readiness history reads D-1..D-4).
	// [0] is the anchor night (identical to Segments). Never duplicate
	// night content elsewhere: SleepStageRecord ids derive from
	// personUuid+startTs, so duplicate starts collide.
	BaselineNights []GoalNight `json:"baseline_nights"`

	// Raw HR/SpO2 samples for RHR/SpO2 baselines (30 nights + anchor night).
	// The generator places them so the Dart DB-derived baselines equal the
	// Go engine's explicit baseline inputs below.
	HR   []HRSample   `json:"hr,omitempty"`
	SpO2 []SpO2Sample `json:"spo2,omitempty"`

	// Go-side baseline inputs (must equal what the Dart DB-derived baselines
	// produce; verified by the comparator's BASELINE_DIFFERENCE check).
	LastNightRhr *float64 `json:"last_night_rhr,omitempty"`
	RhrBaseline  *float64 `json:"rhr_baseline,omitempty"`
	Spo2Tonight  *float64 `json:"spo2_tonight,omitempty"`
	Spo2Baseline *float64 `json:"spo2_baseline,omitempty"`

	// Goal state (F-08/F-09).
	GoalStepsCurrent      int   `json:"goal_steps_current,omitempty"` // 0 = absent (seed prior)
	GoalStepSamples       []int `json:"goal_step_samples,omitempty"`  // D-1..D-30; null = no data
	GoalPriorSteps        int   `json:"goal_prior_steps,omitempty"`
	GoalMaxDailySteps     int   `json:"goal_max_daily_steps,omitempty"`
	GoalLastAutoUpdateMs  int64 `json:"goal_last_auto_update_at_ms,omitempty"`
	GoalManualOverrideMs  int64 `json:"goal_manual_override_at_ms,omitempty"`
	SleepBedCurrent       *int  `json:"sleep_bed_current_minutes,omitempty"`
	SleepTargetCurrent    *int  `json:"sleep_target_current_minutes,omitempty"`
	SleepLastAutoUpdateMs int64 `json:"sleep_last_auto_update_at_ms,omitempty"`
	SleepManualOverrideMs int64 `json:"sleep_manual_override_at_ms,omitempty"`

	// NowMs is the explicit wall-clock for goal cooldown checks.
	NowMs int64 `json:"now_ms,omitempty"`
}

// LoadFixture reads one canonical fixture.
func LoadFixture(path string) (*Fixture, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f Fixture
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if f.FixtureID == "" {
		return nil, fmt.Errorf("%s: fixture_id required", path)
	}
	if f.Timezone == "" {
		return nil, fmt.Errorf("%s: timezone required (must equal runner host zone)", path)
	}
	if f.Timezone != time.Local.String() {
		return nil, fmt.Errorf("%s: fixture timezone %q != host %q (Dart buckets in local time)",
			path, f.Timezone, time.Local.String())
	}
	return &f, nil
}

// LoadFixtures loads every *.json fixture in a directory, sorted by name.
func LoadFixtures(dir string) ([]*Fixture, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, e := range entries {
		if !e.IsDir() && filepath.Ext(e.Name()) == ".json" {
			paths = append(paths, filepath.Join(dir, e.Name()))
		}
	}
	var out []*Fixture
	for _, p := range paths {
		f, err := LoadFixture(p)
		if err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, nil
}
