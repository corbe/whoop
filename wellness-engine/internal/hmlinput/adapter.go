// Bundle → canonical differential Fixture (STAGE 19B, PART A).
//
// Reconstruction approach (19A.6): RHR/SpO2 baselines are DERIVED from raw
// HR/SpO2 samples with the same formulas the app uses (nightly P10 /
// nightly mean over forNight windows, 30-night rolling, shrinkage vs
// priors 65 bpm / 96%). Goal state, battery and session kcal come from a
// sidecar (they are APP_LOCAL in the official path — no backend source).
// Missing sidecar inputs mark the case INPUT_INCOMPLETE; nothing is
// fabricated.
package hmlinput

import (
	"fmt"
	"math"
	"sort"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/differential"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
)

// Sidecar carries the app-local state the backend cannot supply. All
// fields optional; absent fields mark the case incomplete (never guessed).
type Sidecar struct {
	GoalStepsCurrent        int      `json:"goal_steps_current"`
	SleepBedCurrentMinutes  *int     `json:"sleep_bed_current_minutes,omitempty"`
	SleepTargetCurrentMinutes *int   `json:"sleep_target_current_minutes,omitempty"`
	GoalLastAutoUpdateMs    int64    `json:"goal_last_auto_update_at_ms,omitempty"`
	SleepLastAutoUpdateMs   int64    `json:"sleep_last_auto_update_at_ms,omitempty"`
	GoalManualOverrideMs    int64    `json:"goal_manual_override_at_ms,omitempty"`
	SleepManualOverrideMs   int64    `json:"sleep_manual_override_at_ms,omitempty"`
	Gender                  string   `json:"gender,omitempty"` // M/F (prior steps/bed/target)
	BirthDate               string   `json:"birth_date,omitempty"`
	Battery                 []BatterySample `json:"battery,omitempty"`
	SessionKcal             int      `json:"session_kcal,omitempty"`
}

// BatterySample mirrors the canonical battery sample.
type BatterySample struct {
	Ms    int64   `json:"ms"`
	Value float64 `json:"value"`
}

// BuildFixture converts one person-day into the canonical fixture.
// day is the logical anchor day (local); loc is the runtime zone.
// Returns the fixture plus a completeness report. Incomplete reasons are
// explicit — INPUT_INCOMPLETE cases are NOT engine mismatches.
func BuildFixture(b *Bundle, side *Sidecar, day time.Time, loc *time.Location, personUUID string) (*differential.Fixture, []string, error) {
	var incomplete []string
	ws, we := domain.NightWindow(day, loc)

	// 1) sleep segments: anchor night + 30 baseline nights from hipnograma.
	anchor, baselineNights, err := segmentsFromHipnograma(b.Hipnograma, day, loc, ws, we)
	if err != nil {
		return nil, nil, err
	}

	// 2) HRV samples (raw; the Go runner buckets by local dayKey like the
	// Dart services).
	hrv := make([]differential.HRVSample, 0, len(b.HRV))
	for _, p := range b.HRV {
		hrv = append(hrv, differential.HRVSample{Ms: p.TimestampMs, Value: p.Value})
	}

	// 3) steps (value only from the backend; calories/distance ABSENT).
	var steps []differential.StepRecord
	for _, p := range b.Steps {
		t := time.UnixMilli(p.TimestampMs).In(loc)
		if t.Year() == day.Year() && t.YearDay() == day.YearDay() {
			steps = append(steps, differential.StepRecord{Value: p.Value, Ms: p.TimestampMs, Device: "API"})
		}
	}
	stepsCaloriesMissing := true // backend 'passos' payload carries value only

	// 4) RHR/SpO2 baselines — RECONSTRUCTION from raw HR/SpO2 samples.
	hrSamples := make([]differential.HRSample, 0, len(b.HR))
	for _, p := range b.HR {
		hrSamples = append(hrSamples, differential.HRSample{Ms: p.TimestampMs, Value: p.Value})
	}
	spo2Samples := make([]differential.SpO2Sample, 0, len(b.SpO2))
	for _, p := range b.SpO2 {
		spo2Samples = append(spo2Samples, differential.SpO2Sample{Ms: p.TimestampMs, Value: p.Value})
	}
	lastRhr, rhrBase := deriveRhr(hrSamples, day, loc, ws, we)
	spo2Tonight, spo2Base := deriveSpo2(spo2Samples, day, loc, ws, we)

	// 5) sleep history: the canonical harness derives it from the goal
	// effective bed/target — but here we cannot run goals before knowing the
	// fixture. The Go runner reads fixture.SleepHistory directly, so the
	// adapter computes it the same way the generator does (goal-effective
	// config), using the sidecar goal state.
	history, effBed, effTarget, goalRes := deriveSleepHistory(baselineNights, side, day, loc)

	// 6) goal state + battery/session sidecar.
	goalCurrent := 0
	if side != nil {
		goalCurrent = side.GoalStepsCurrent
	}
	if stepsCaloriesMissing && (side == nil || side.SessionKcal == 0) {
		// Activity totalKcal is ambiguous without calories/session: the
		// official path uses SDK record calories (backend carries value
		// only), the shadow would use 0. Do NOT fabricate — flag the case.
		incomplete = append(incomplete, "steps_calories_distance_unavailable")
	}
	if side == nil || (side.Gender == "" && side.BirthDate == "") {
		incomplete = append(incomplete, "demographics_unavailable")
	}

	var battery []differential.BatterySample
	sessionKcal := 0
	if side != nil {
		for _, b := range side.Battery {
			battery = append(battery, differential.BatterySample{Ms: b.Ms, Value: b.Value})
		}
		sessionKcal = side.SessionKcal
	}

	f := &differential.Fixture{
		FixtureID:        fmt.Sprintf("hml_%s_%s", personUUID, day.Format("2006-01-02")),
		PersonID:         personUUID, // caller passes the pseudonym
		Day:              day.Format("2006-01-02"),
		Timezone:         loc.String(),
		Segments:         anchor,
		HRV:              hrv,
		Battery:          battery,
		Steps:            steps,
		SessionKcal:      sessionKcal,
		SleepHistory:     history,
		BaselineNights:   baselineNights,
		HR:               hrSamples,
		SpO2:             spo2Samples,
		LastNightRhr:     lastRhr,
		RhrBaseline:      rhrBase,
		Spo2Tonight:      spo2Tonight,
		Spo2Baseline:     spo2Base,
		GoalStepsCurrent: goalCurrent,
		GoalPriorSteps:   7500,
		GoalMaxDailySteps: 15000,
		GoalLastAutoUpdateMs: sideGoalMs(side, true),
		SleepBedCurrent:    sideBed(side),
		SleepTargetCurrent: sideTarget(side),
		SleepLastAutoUpdateMs: sideSleepMs(side),
		NowMs:             time.Now().UTC().UnixMilli(),
	}
	_ = effBed
	_ = effTarget
	_ = goalRes
	return f, incomplete, nil
}

func sideGoalMs(s *Sidecar, _ bool) int64 {
	if s == nil {
		return 0
	}
	return s.GoalLastAutoUpdateMs
}

func sideSleepMs(s *Sidecar) int64 {
	if s == nil {
		return 0
	}
	return s.SleepLastAutoUpdateMs
}

func sideBed(s *Sidecar) *int {
	if s == nil {
		return nil
	}
	return s.SleepBedCurrentMinutes
}

func sideTarget(s *Sidecar) *int {
	if s == nil {
		return nil
	}
	return s.SleepTargetCurrentMinutes
}

// segmentsFromHipnograma converts raw hipnograma items into the anchor night
// segments and the 30 baseline nights (D-1..D-30), mirroring the app's
// conversion (transitions → contiguous segments; direct {start,end,type}
// maps as-is; raw stage ints preserved).
func segmentsFromHipnograma(items []HipnogramaItem, day time.Time, loc *time.Location, ws, we int64) ([]differential.Segment, []differential.GoalNight, error) {
	var direct []differential.Segment
	var transitions []struct{ t, stage int64 }
	for _, it := range items {
		if it.IsTransition {
			transitions = append(transitions, struct{ t, stage int64 }{it.TransitionT, int64(it.Stage)})
		} else if it.EndMs > it.StartMs {
			direct = append(direct, differential.Segment{StartMs: it.StartMs, EndMs: it.EndMs, Stage: int8(it.Stage)})
		}
	}
	var segs []differential.Segment
	if len(direct) > 0 {
		segs = direct
	} else if len(transitions) > 1 {
		sort.Slice(transitions, func(i, j int) bool { return transitions[i].t < transitions[j].t })
		for i := 0; i < len(transitions)-1; i++ {
			segs = append(segs, differential.Segment{
				StartMs: transitions[i].t, EndMs: transitions[i+1].t, Stage: int8(transitions[i].stage),
			})
		}
	}
	// filter to [ws, we) window for the anchor night
	var anchor []differential.Segment
	for _, s := range segs {
		if s.StartMs >= ws && s.EndMs <= we {
			anchor = append(anchor, s)
		}
	}
	// baseline nights D-1..D-30: segments within each night's window
	nights := make([]differential.GoalNight, 30)
	for i := 0; i < 30; i++ {
		nd := day.AddDate(0, 0, -(i + 1))
		ns, ne := domain.NightWindow(nd, loc)
		var nsegs []differential.Segment
		for _, s := range segs {
			if s.StartMs >= ns && s.EndMs <= ne {
				nsegs = append(nsegs, s)
			}
		}
		nights[i] = differential.GoalNight{Date: nd.Format("2006-01-02"), Segments: nsegs}
	}
	return anchor, nights, nil
}

// deriveRhr reconstructs lastNightRhr + rolling RHR baseline (same formulas
// as WellnessBaselines: nightly P10 over the forNight window, 30-night
// median, shrinkage blend vs 65 with w = n/30).
func deriveRhr(samples []differential.HRSample, day time.Time, loc *time.Location, ws, we int64) (*float64, *float64) {
	nightly := func(d time.Time, s, e int64) *float64 {
		var vals []float64
		for _, h := range samples {
			if h.Ms >= s && h.Ms < e && h.Value > 30 && h.Value < 220 {
				vals = append(vals, h.Value)
			}
		}
		if len(vals) == 0 {
			return nil
		}
		sort.Float64s(vals)
		idx := int(float64(len(vals))*0.1)
		if idx > len(vals)-1 {
			idx = len(vals) - 1
		}
		v := vals[idx]
		return &v
	}
	last := nightly(day, ws, we)
	var rolling []float64
	for i := 1; i <= 30; i++ {
		d := day.AddDate(0, 0, -i)
		ns, ne := domain.NightWindow(d, loc)
		if v := nightly(d, ns, ne); v != nil {
			rolling = append(rolling, *v)
		}
	}
	var base *float64
	if len(rolling) > 0 {
		sort.Float64s(rolling)
		med := rolling[len(rolling)/2]
		if len(rolling)%2 == 0 {
			med = (rolling[len(rolling)/2-1] + rolling[len(rolling)/2]) / 2
		}
		w := math.Min(1.0, float64(len(rolling))/30.0)
		v := w*med + (1-w)*65.0
		base = &v
	}
	return last, base
}

// deriveSpo2 mirrors WellnessBaselines: nightly mean of SpO2 samples in the
// window (70..100), 30-night rolling mean, shrinkage vs 96.
func deriveSpo2(samples []differential.SpO2Sample, day time.Time, loc *time.Location, ws, we int64) (*float64, *float64) {
	nightly := func(d time.Time, s, e int64) *float64 {
		var sum, n float64
		for _, o := range samples {
			if o.Ms >= s && o.Ms < e && o.Value >= 70 && o.Value <= 100 {
				sum += o.Value
				n++
			}
		}
		if n == 0 {
			return nil
		}
		v := sum / n
		return &v
	}
	tonight := nightly(day, ws, we)
	var rolling []float64
	for i := 1; i <= 30; i++ {
		d := day.AddDate(0, 0, -i)
		ns, ne := domain.NightWindow(d, loc)
		if v := nightly(d, ns, ne); v != nil {
			rolling = append(rolling, *v)
		}
	}
	var base *float64
	if len(rolling) > 0 {
		sum := 0.0
		for _, v := range rolling {
			sum += v
		}
		mean := sum / float64(len(rolling))
		w := math.Min(1.0, float64(len(rolling))/30.0)
		v := w*mean + (1-w)*96.0
		base = &v
	}
	return tonight, base
}

// deriveSleepHistory computes the 4 history night scores with the
// goal-effective bed/target (mirroring the generator's approach) so the
// fixture is self-consistent for the Go runner.
func deriveSleepHistory(nights []differential.GoalNight, side *Sidecar, day time.Time, loc *time.Location) ([]int, int, int, bool) {
	// Minimal goal-state effective config: currents ?? defaults (1320/480);
	// no update application here (the shadow runner's engine applies updates
	// itself via CalculateDayDetailed). The official app also recomputes
	// history with its CURRENT effective config — the fixture history must
	// match what the Dart sees: currents ?? seeded defaults.
	bed, target := 1320, 480
	if side != nil {
		if side.SleepBedCurrentMinutes != nil {
			bed = *side.SleepBedCurrentMinutes
		}
		if side.SleepTargetCurrentMinutes != nil {
			target = *side.SleepTargetCurrentMinutes
		}
	}
	history := make([]int, 4)
	for i := 0; i < 4 && i < len(nights); i++ {
		nd, _ := time.ParseInLocation("2006-01-02", nights[i].Date, loc)
		history[i] = differential.NightSleepScore(nights[i].Segments, nd, bed, target)
	}
	return history, bed, target, false
}
