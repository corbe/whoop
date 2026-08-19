// Normalized result shape + Go runner (STAGE 18.4/18.5). The Dart runner
// produces the SAME shape. Every field is COMPARABLE — metadata that only
// one side has is deliberately NOT emitted.
package differential

import (
	"fmt"
	"sort"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/goals"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/night"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/activity"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/sleep"
)

// Result is the normalized, comparable output of one fixture on one side.
type Result struct {
	FixtureID string `json:"fixture_id"`
	Scores    struct {
		Sleep     int `json:"sleep"`
		Stress    int `json:"stress"`
		Readiness int `json:"readiness"`
		Activity  int `json:"activity"`
	} `json:"scores"`
	Sleep struct {
		Score   int  `json:"score"`
		Msg1    int  `json:"msg1"`
		Msg2    int  `json:"msg2"`
		Msg3    int  `json:"msg3"`
		Battery bool `json:"battery_depleted"`
	} `json:"sleep"`
	Stress struct {
		Score        int     `json:"score"`
		DownCount    int     `json:"down_count"`
		BaselineMs   float64 `json:"baseline_ms"`
		InstantHrvMs float64 `json:"instant_hrv_ms"`
	} `json:"stress"`
	Readiness struct {
		Score             int  `json:"score"`
		SleepComponent    int  `json:"sleep_component"`
		RecoveryComponent int  `json:"recovery_component"`
		RhrComponent      *int `json:"rhr_component"`
		Spo2Component     *int `json:"spo2_component"`
		FatigueComponent  *int `json:"fatigue_component"`
	} `json:"readiness"`
	Activity struct {
		Score     int `json:"score"`
		DayTarget int `json:"day_target"`
		ZoneStart int `json:"zone_start"`
		ZoneEnd   int `json:"zone_end"`
		GoalSteps int `json:"goal_steps"`
		GoalKcal  int `json:"goal_kcal"`
		TotalKcal int `json:"total_kcal"`
	} `json:"activity"`
	Goals struct {
		StepsUpdated   bool `json:"steps_updated"`
		NewStepsGoal   *int `json:"new_steps_goal"`
		SleepUpdated   bool `json:"sleep_updated"`
		NewBedTime     *int `json:"new_bed_time"`
		NewSleepTarget *int `json:"new_sleep_target"`
	} `json:"goals"`
	Baselines struct {
		StepsValue      float64 `json:"steps_value"`
		StepsCount      int     `json:"steps_count"`
		StepsConfidence string  `json:"steps_confidence"`
		BedTime         int     `json:"bed_time_minutes"`
		SleepTarget     int     `json:"sleep_target_minutes"`
		SleepCount      int     `json:"sleep_count"`
		SleepConfidence string  `json:"sleep_confidence"`
	} `json:"baselines"`
}

// GoRunner executes one fixture through the REAL Go engine
// (engine.CalculateDayDetailed — no HTTP, no transport).
type GoRunner struct {
	cfg engine.Configs
}

func NewGoRunner(cfg engine.Configs) *GoRunner { return &GoRunner{cfg: cfg} }

// Run converts the fixture to engine.Input (deriving the daily HRV averages
// and night HRV the same way the Dart services derive them from raw
// records) and returns the normalized result.
func (g *GoRunner) Run(f *Fixture) (*Result, error) {
	in, err := fixtureToInput(f)
	if err != nil {
		return nil, err
	}
	bundle, err := engine.CalculateDayDetailed(in, g.cfg)
	if err != nil {
		return nil, fmt.Errorf("calculate: %w", err)
	}
	return ResultFromBundle(f.FixtureID, in, bundle)
}

// fixtureToInput mirrors the DART service derivations from the raw fixture
// records (host-local bucketing — the Dart services bucket in local time):
//   - night HRV: samples within [18:00 D-1, 12:00 D] local
//   - daily averages: mean per local day over samples with value > 0,
//     days ascending (dayKey order = chronological)
//   - instant HRV: all samples (the engine's InstantHRVMs filters windows)
func fixtureToInput(f *Fixture) (engine.Input, error) {
	day, err := time.ParseInLocation("2006-01-02", f.Day, time.Local)
	if err != nil {
		return engine.Input{}, fmt.Errorf("day %q: %w", f.Day, err)
	}
	loc := time.Local
	wsMs, weMs := domain.NightWindow(day, loc)

	// 1) night HRV (value > 0, within night window)
	var nightHRV []float64
	// 2) daily averages bucketed by local dayKey (year*400+month*31+day)
	type bucket struct {
		key   int
		sum   float64
		count int
	}
	buckets := map[int]*bucket{}
	var keys []int
	addSample := func(ms int64, v float64) {
		if v <= 0 {
			return
		}
		if ms >= wsMs && ms < weMs {
			nightHRV = append(nightHRV, v)
		}
		t := time.UnixMilli(ms).In(loc)
		k := t.Year()*400 + int(t.Month())*31 + t.Day()
		b, ok := buckets[k]
		if !ok {
			b = &bucket{key: k}
			buckets[k] = b
			keys = append(keys, k)
		}
		b.sum += v
		b.count++
	}
	var instant []float64
	var instantTs []int64
	for _, s := range f.HRV {
		addSample(s.Ms, s.Value)
		instant = append(instant, s.Value)
		instantTs = append(instantTs, s.Ms)
	}
	sort.Ints(keys)
	var daily []float64
	for _, k := range keys {
		daily = append(daily, buckets[k].sum/float64(buckets[k].count))
	}

	segments := make([]domain.Segment, len(f.Segments))
	for i, s := range f.Segments {
		segments[i] = domain.Segment{StartMs: s.StartMs, EndMs: s.EndMs, Stage: domain.Stage(s.Stage)}
	}
	var battery []night.BatterySample
	for _, b := range f.Battery {
		battery = append(battery, night.BatterySample{TimestampMs: b.Ms, Value: b.Value})
	}
	steps := make([]activity.StepsRecord, len(f.Steps))
	for i, s := range f.Steps {
		steps[i] = activity.StepsRecord{
			Value: s.Value, Calories: s.Calories, DistanceM: s.DistanceM,
			Timestamp: s.Ms, Device: domain.DeviceSource(s.Device),
		}
	}
	// ALWAYS non-nil so the engine runs the steps-goal baselines (the Dart
	// runner always calls maybeAutoUpdateAll): empty → baseline = prior,
	// confidence none, no update.
	goalSamples := []int{}
	if f.GoalStepSamples != nil {
		goalSamples = f.GoalStepSamples
	}
	var bedtimes, durations []int
	// ALWAYS non-nil so the engine runs the sleep-goal baselines (mirroring
	// the Dart runner, which always calls computeSleepBaselines): empty →
	// baseline = priors, confidence none. F-09 window = D-1..D-21 =
	// BaselineNights[0:21] (the Dart bedtimeBaseline iterates the same 21).
	if f.BaselineNights != nil {
		nights := f.BaselineNights
		if len(nights) > 21 {
			nights = nights[:21]
		}
		bedtimes = make([]int, 0, len(nights))
		durations = make([]int, 0, len(nights))
		for _, n := range nights {
			na, err := time.ParseInLocation("2006-01-02", n.Date, loc)
			if err != nil {
				return engine.Input{}, err
			}
			bt, dur, err := nightStats(n.Segments, na, loc)
			if err != nil {
				return engine.Input{}, err
			}
			bedtimes = append(bedtimes, bt)
			durations = append(durations, dur)
		}
	} else {
		bedtimes = []int{}
		durations = []int{}
	}
	in := engine.Input{
		PersonID:             f.PersonID,
		Date:                 day,
		Location:             loc,
		Segments:             segments,
		HRVMs:                nightHRV,
		Battery:              battery,
		DailyHrvAverages:     daily,
		InstantHrvSamples:    instant,
		InstantHrvTimestamps: instantTs,
		SleepHistoryScores:   f.SleepHistory,
		FatigueHistoryScores: fatigueOf(f.SleepHistory),
		LastNightRhr:         f.LastNightRhr,
		RhrBaseline:          f.RhrBaseline,
		Spo2Tonight:          f.Spo2Tonight,
		Spo2Baseline:         f.Spo2Baseline,
		StepsRecords:         steps,
		SessionKcal:          f.SessionKcal,
		GoalSteps:            f.GoalStepsCurrent,
		GoalStepSamples:      goalSamples,
		GoalPriorSteps:       f.GoalPriorSteps,
		GoalMaxDailySteps:    f.GoalMaxDailySteps,
		GoalState: goals.StepsState{
			CurrentGoal:      f.GoalStepsCurrent,
			LastAutoUpdateAt: msPtr(f.GoalLastAutoUpdateMs),
			ManualOverrideAt: msPtr(f.GoalManualOverrideMs),
		},
		BedtimeMinutes:  bedtimes,
		DurationMinutes: durations,
		SleepGoalState: goals.SleepState{
			CurrentBedTime:     f.SleepBedCurrent,
			CurrentSleepTarget: f.SleepTargetCurrent,
			LastAutoUpdateAt:   msPtr(f.SleepLastAutoUpdateMs),
			ManualOverrideAt:   msPtr(f.SleepManualOverrideMs),
		},
		Now: nowValue(f.NowMs),
	}
	return in, nil
}

// ResultFromBundle maps a bundle to the normalized shape.
func ResultFromBundle(id string, in engine.Input, b *engine.CalculationBundle) (*Result, error) {
	r := &Result{FixtureID: id}
	r.Scores.Sleep = b.Scores.Sleep.Score
	r.Scores.Stress = b.Scores.Stress.Score
	if b.Scores.Readiness != nil {
		r.Scores.Readiness = b.Scores.Readiness.TotalScore
	}
	r.Scores.Activity = b.Scores.Activity.ActivityScore
	r.Sleep.Score = b.Scores.Sleep.Score
	r.Sleep.Msg1 = b.Scores.Sleep.Msg1
	r.Sleep.Msg2 = b.Scores.Sleep.Msg2
	r.Sleep.Msg3 = b.Scores.Sleep.Msg3
	r.Sleep.Battery = b.Scores.Sleep.BateriaZerada
	r.Stress.Score = b.Scores.Stress.Score
	r.Stress.DownCount = b.Scores.Stress.DownCount
	r.Stress.BaselineMs = b.Scores.Stress.BaselineMs
	r.Stress.InstantHrvMs = b.Scores.InstantHrvMs
	if b.Scores.Readiness != nil {
		bd := b.Scores.Readiness
		r.Readiness.Score = bd.TotalScore
		r.Readiness.SleepComponent = bd.SleepComponent
		r.Readiness.RecoveryComponent = bd.RecoveryComponent
		r.Readiness.RhrComponent = bd.RhrComponent
		r.Readiness.Spo2Component = bd.Spo2Component
		r.Readiness.FatigueComponent = bd.FatigueComponent
	}
	a := b.Scores.Activity
	r.Activity.Score = a.ActivityScore
	r.Activity.DayTarget = a.DayTargetPercent
	r.Activity.ZoneStart = a.ZoneStartPercent
	r.Activity.ZoneEnd = a.ZoneEndPercent
	r.Activity.GoalSteps = a.GoalSteps
	r.Activity.GoalKcal = a.GoalKcal
	r.Activity.TotalKcal = a.TotalKcal
	r.Goals.StepsUpdated = b.Goals.Steps.Updated
	r.Goals.NewStepsGoal = b.Goals.Steps.NewGoal
	r.Goals.SleepUpdated = b.Goals.Sleep.Updated
	r.Goals.NewBedTime = b.Goals.Sleep.NewBedTime
	r.Goals.NewSleepTarget = b.Goals.Sleep.NewSleepTarget
	r.Baselines.StepsValue = b.Goals.Steps.Baseline.Value
	r.Baselines.StepsCount = b.Goals.Steps.Baseline.SampleCount
	r.Baselines.StepsConfidence = b.Goals.Steps.Baseline.Confidence.String()
	r.Baselines.BedTime = b.Goals.Sleep.BedTimeMinutes
	r.Baselines.SleepTarget = b.Goals.Sleep.SleepTargetMinutes
	r.Baselines.SleepCount = b.Goals.Sleep.SampleCount
	r.Baselines.SleepConfidence = b.Goals.Sleep.Confidence.String()
	return r, nil
}

func fatigueOf(history []int) []int {
	if len(history) < 3 {
		return history
	}
	return history[:3]
}

func msPtr(ms int64) *time.Time { return msTime(ms) }

func msTime(ms int64) *time.Time {
	if ms <= 0 {
		return nil
	}
	t := time.UnixMilli(ms)
	return &t
}

func nowValue(ms int64) time.Time {
	if ms <= 0 {
		return time.Time{}
	}
	return time.UnixMilli(ms)
}

// nightStats computes the normalized bedtime + effective duration of a
// canonical night via the REAL night pipeline (golden-verified). Bedtime =
// normalized minute-of-day of the processed night start (Dart: +1440 when
// < 720, matching bedtimeBaseline).
func nightStats(segments []Segment, anchor time.Time, loc *time.Location) (int, int, error) {
	segs := make([]domain.Segment, len(segments))
	for i, s := range segments {
		segs[i] = domain.Segment{StartMs: s.StartMs, EndMs: s.EndMs, Stage: domain.Stage(s.Stage)}
	}
	summary := night.ForNight(night.Input{Segments: segs, Location: loc, AnchorDate: anchor})
	if summary.IsEmpty() {
		return 0, 0, nil
	}
	t := time.UnixMilli(summary.StartMs).In(loc)
	bed := t.Hour()*60 + t.Minute()
	if bed < 720 {
		bed += 1440
	}
	return bed, int(summary.SleepingTimeMs() / 60000), nil
}

// NightSleepScore exposes the golden-verified sleep score computation for a
// canonical night (used by the HML adapter to derive self-consistent
// history scores with a given bed/target).
func NightSleepScore(segments []Segment, anchor time.Time, bed, target int) int {
	if len(segments) == 0 {
		return 0
	}
	segs := make([]domain.Segment, len(segments))
	for i, s := range segments {
		segs[i] = domain.Segment{StartMs: s.StartMs, EndMs: s.EndMs, Stage: domain.Stage(s.Stage)}
	}
	summary := night.ForNight(night.Input{Segments: segs, Location: time.Local, AnchorDate: anchor})
	if summary.IsEmpty() {
		return 0
	}
	return sleep.Compute(summary, bed, target, engine.DefaultConfigs().Sleep).Score
}
