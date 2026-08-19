// Deterministic synthetic corpus generator (STAGE 18.9/18.10).
//
// Fixed seed → reproducible fixtures covering: night templates (ideal,
// short, long, stage-varied, empty, battery-low, degenerate, capped),
// HRV daily series variations, missing days, steps extremes, SpO2/RHR
// variations, goal updates (incl. cooldown/override), history nights.
// All values stay inside the audited valid ranges unless a case
// deliberately tests invalid-input behavior (battery-low, empty night).
//
// Every fixture's sleep_history is DERIVED from its history-night segments
// via the golden-verified Go sleep pipeline, so both runners agree on the
// same underlying data.
package differential

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/goals"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/night"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/scoring/sleep"
)

// NightTemplate is a canonical night recipe.
type NightTemplate struct {
	Name     string
	Segments []Segment
}

func msLocal(y int, mo time.Month, d, h, mi int) int64 {
	return time.Date(y, mo, d, h, mi, 0, 0, time.Local).UnixMilli()
}

// nightAnchor returns the anchor (midnight) of day "YYYY-MM-DD".
func dayAnchor(s string) time.Time {
	t, _ := time.ParseInLocation("2006-01-02", s, time.Local)
	return t
}

// templates returns canonical nights anchored at the given date D.
// Each night's segments span [start, end] with start in the evening of
// D-1 and end in the morning of D.
func templates(d time.Time) map[string]NightTemplate {
	// helper: night segments from (startH, startM, durMin) with stage recipe
	mk := func(startDayOffset, startH, startM, durMin int, stages []struct {
		frac  float64
		stage int8
	}) []Segment {
		start := time.Date(d.Year(), d.Month(), d.Day()+startDayOffset, startH, startM, 0, 0, time.Local)
		var segs []Segment
		cur := start
		for _, st := range stages {
			span := time.Duration(float64(durMin) * st.frac * float64(time.Minute))
			segs = append(segs, Segment{
				StartMs: cur.UnixMilli(),
				EndMs:   cur.Add(span).UnixMilli(),
				Stage:   st.stage,
			})
			cur = cur.Add(span)
		}
		return segs
	}
	ideal := []struct {
		frac  float64
		stage int8
	}{
		{0.45, -3}, {0.30, -4}, {0.25, -1},
	}
	return map[string]NightTemplate{
		// 22:00→06:00, rem 25%, deep 30%, light 45% → sleep 100
		"ideal": {Name: "ideal", Segments: mk(-1, 22, 0, 480, ideal)},
		// 22:00→06:00, rem 8%, deep 20% → quality 5 → 95
		"low_rem": {Name: "low_rem", Segments: mk(-1, 22, 0, 480, []struct {
			frac  float64
			stage int8
		}{{0.72, -3}, {0.20, -4}, {0.08, -1}})},
		// 22:00→04:30 (6.5h): duration diff2 = -90 → 15; rem 25% deep 25% → 85
		"short_65h": {Name: "short_65h", Segments: mk(-1, 22, 0, 390, []struct {
			frac  float64
			stage int8
		}{{0.45, -3}, {0.30, -4}, {0.25, -1}})},
		// 23:30→07:30: bedtime +90 → 15 (heavy boundary), rem 25% deep 25% → 85
		"late_90": {Name: "late_90", Segments: mk(-1, 23, 30, 480, ideal)},
		// 00:30→07:30: bedtime +150 → 15+16=31 → 69; rem 12%, deep 12% → quality 8 → 61
		"very_late": {Name: "very_late", Segments: mk(0, 0, 30, 420, []struct {
			frac  float64
			stage int8
		}{{0.70, -3}, {0.15, -4}, {0.15, -1}})},
		// empty (no data) → 0
		"empty": {Name: "empty", Segments: nil},
		// 22:00→06:00 with a 2h awake gap in the middle (expunged) → 100
		"awake_gap": {Name: "awake_gap", Segments: []Segment{
			{StartMs: msLocal(d.Year(), d.Month(), d.Day()-1, 22, 0), EndMs: msLocal(d.Year(), d.Month(), d.Day()-1, 23, 0), Stage: -3},
			{StartMs: msLocal(d.Year(), d.Month(), d.Day()-1, 23, 0), EndMs: msLocal(d.Year(), d.Month(), d.Day()-1, 23, 30), Stage: 0},
			{StartMs: msLocal(d.Year(), d.Month(), d.Day()-1, 23, 30), EndMs: msLocal(d.Year(), d.Month(), d.Day(), 1, 0), Stage: -4},
			{StartMs: msLocal(d.Year(), d.Month(), d.Day(), 1, 0), EndMs: msLocal(d.Year(), d.Month(), d.Day(), 1, 30), Stage: 0},
			{StartMs: msLocal(d.Year(), d.Month(), d.Day(), 1, 30), EndMs: msLocal(d.Year(), d.Month(), d.Day(), 2, 30), Stage: -1},
			{StartMs: msLocal(d.Year(), d.Month(), d.Day(), 2, 30), EndMs: msLocal(d.Year(), d.Month(), d.Day(), 6, 0), Stage: -3},
		}},
		// 18:00→12:00 (18h) → 16h cap
		"capped_16h": {Name: "capped_16h", Segments: []Segment{
			{StartMs: msLocal(d.Year(), d.Month(), d.Day()-1, 18, 0), EndMs: msLocal(d.Year(), d.Month(), d.Day(), 12, 0), Stage: -3},
		}},
	}
}

// sleepScoreOf computes the sleep score of a template night via the REAL
// Go pipeline (golden-verified) — fixtures are self-consistent by construction.
func sleepScoreOf(t NightTemplate, anchor time.Time, bed, target int) int {
	if len(t.Segments) == 0 {
		return 0
	}
	segs := make([]domain.Segment, len(t.Segments))
	for i, s := range t.Segments {
		segs[i] = domain.Segment{StartMs: s.StartMs, EndMs: s.EndMs, Stage: domain.Stage(s.Stage)}
	}
	summary := night.ForNight(night.Input{Segments: segs, Location: time.Local, AnchorDate: anchor})
	if summary.IsEmpty() {
		return 0
	}
	return sleep.Compute(summary, bed, target, engine.DefaultConfigs().Sleep).Score
}

// GenerateCorpus writes N deterministic synthetic fixtures to dir.
func GenerateCorpus(dir string, n int, seed int64) ([]string, error) {
	rng := rand.New(rand.NewSource(seed))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	var ids []string
	for i := 0; i < n; i++ {
		f, err := synthFixture(rng, i)
		if err != nil {
			return nil, err
		}
		raw, _ := json.MarshalIndent(f, "", "  ")
		id := fmt.Sprintf("%s", f.FixtureID)
		if err := os.WriteFile(filepath.Join(dir, id+".json"), raw, 0o644); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, nil
}

func synthFixture(rng *rand.Rand, i int) (*Fixture, error) {
	day := time.Date(2026, 8, 10, 0, 0, 0, 0, time.Local)
	now := time.Date(2026, 8, 10, 12, 0, 0, 0, time.UTC)
	past := now.Add(-8 * 24 * time.Hour)

	names := []string{"ideal", "low_rem", "short_65h", "late_90", "very_late", "empty", "awake_gap", "capped_16h"}
	pick := func() string {
		n := names[rng.Intn(len(names))]
		if rng.Intn(10) == 0 {
			n = "empty"
		}
		return n
	}
	// Templates are anchored per night (their segments must fall inside that
	// night's own window) — build them fresh for each night.
	nightTemplate := func(nightDay time.Time, name string) NightTemplate {
		return templates(nightDay)[name]
	}
	anchorName := pick()
	anchor := nightTemplate(day, anchorName)

	// BaselineNights: the SINGLE segment source — 30 nights anchored at
	// D-1..D-30 (the night BEFORE the anchor day: [0] is the D-1 night, NOT
	// the anchor night!). [0..3] feed readiness history, [0..20] feed F-09,
	// all 30 feed the RHR/SpO2 rolling windows. The anchor night (day D)
	// lives in `segments` and feeds today's sleep + lastNightRhr/spo2Tonight.
	baselineNights := make([]GoalNight, 30)
	chosen := make([]string, 30)
	for i := 0; i < 30; i++ {
		name := anchorName
		if i > 0 {
			name = pick()
		}
		chosen[i] = name
		nightDay := day.AddDate(0, 0, -(i + 1))
		baselineNights[i] = GoalNight{
			Date:     nightDay.Format("2006-01-02"),
			Segments: nightTemplate(nightDay, name).Segments,
		}
	}
	// RHR/SpO2 rolling contribution: nights whose forNight summary is
	// non-empty AND whose night window contains HR samples. Empty and
	// capped_16h templates yield no usable window (capped → degenerate
	// [18:00,18:00] window → HR query empty), so they are skipped by the
	// Dart rolling — the fixture baselines are DERIVED from the same count.
	contributing := 0
	for i := 0; i < 30; i++ {
		if chosen[i] != "empty" && chosen[i] != "capped_16h" {
			contributing++
		}
	}

	// HRV: 21 days × 3 samples + night samples + instant samples
	var hrv []HRVSample
	base := 40 + rng.Float64()*40
	for d := 0; d < 21; d++ {
		dd := day.AddDate(0, 0, -d)
		v := base + (rng.Float64()-0.5)*20
		if v < 15 {
			v = 15
		}
		for _, hh := range []int{11, 12, 13} {
			hrv = append(hrv, HRVSample{Ms: msLocal(dd.Year(), dd.Month(), dd.Day(), hh, 0), Value: v})
		}
	}
	// night HRV samples inside the anchor night [18:00 D-1, 12:00 D]
	nv := 30 + rng.Float64()*30
	for h := 1; h <= 5; h++ {
		hrv = append(hrv, HRVSample{Ms: msLocal(day.Year(), day.Month(), day.Day(), h, 0), Value: nv})
	}
	// instant HRV at 23:50 D-1 (inside the 15-min instant window)
	hrv = append(hrv, HRVSample{Ms: msLocal(day.Year(), day.Month(), day.Day()-1, 23, 50), Value: 40 + rng.Float64()*30})

	// battery: sometimes depleted
	var battery []BatterySample
	if rng.Intn(8) == 0 {
		battery = append(battery,
			BatterySample{Ms: msLocal(day.Year(), day.Month(), day.Day(), 5, 0), Value: 2.5})
	} else if rng.Intn(3) == 0 {
		battery = append(battery,
			BatterySample{Ms: msLocal(day.Year(), day.Month(), day.Day(), 5, 0), Value: 65 + rng.Float64()*30})
	}

	// steps + session kcal
	var steps []StepRecord
	if rng.Intn(10) != 0 { // occasionally no data
		st := rng.Float64() * 15000
		steps = append(steps, StepRecord{
			Value: st, Calories: st * 0.04, DistanceM: st * 0.8,
			Ms: msLocal(day.Year(), day.Month(), day.Day(), 12, 0), Device: "BRACELET",
		})
	}
	sessionKcal := rng.Intn(300)

	// RHR / SpO2: pattern values for the per-night seeds; the fixture
	// baselines are the shrinkage-blended values the Dart rolling derives
	// from the contributing nights (w = n/30, priors 65 bpm / 96%).
	rhrP10 := 55 + rng.Float64()*20
	lastRhr := rhrP10 + (rng.Float64()-0.5)*8
	spo2Mean := 92 + rng.Float64()*6
	if spo2Mean > 99 {
		spo2Mean = 99
	}
	spo2Tonight := spo2Mean + (rng.Float64()-0.5)*3
	if spo2Tonight < 90 {
		spo2Tonight = 90
	}
	if spo2Tonight > 99 {
		spo2Tonight = 99
	}
	w := float64(contributing) / 30.0
	rhrBase := rhrP10*w + 65.0*(1.0-w)
	spo2Base := spo2Mean*w + 96.0*(1.0-w)

	var hrSamples []HRSample
	var spo2Samples []SpO2Sample
	// nightly P10 pattern: the Dart P10 = sorted[floor(0.1*n)] = sorted[1]
	// for n=10. Fillers must be STRICTLY GREATER than target so sorted[1] ==
	// target for ANY target (fixed fillers like 70/75 interleave when
	// target >= 70 and shift the P10).
	seedNightHR := func(nightDay time.Time, target float64) {
		vals := []float64{target, target, target + 6, target + 11, target + 16, target + 21, target + 26, target + 31, target + 36, target + 41}
		for j, v := range vals {
			hrSamples = append(hrSamples, HRSample{
				Ms: msLocal(nightDay.Year(), nightDay.Month(), nightDay.Day(), 2, j), Value: v,
			})
		}
	}
	seedNightSpO2 := func(nightDay time.Time, mean float64) {
		for j := 0; j < 3; j++ {
			spo2Samples = append(spo2Samples, SpO2Sample{
				Ms: msLocal(nightDay.Year(), nightDay.Month(), nightDay.Day(), 2, j*30), Value: mean,
			})
		}
	}
	// anchor night (day D): P10 = lastRhr, mean = spo2Tonight — NOT part of
	// the rolling windows (those cover D-1..D-30). All 30 rolling nights get
	// the same pattern (P10 = rhrP10 / mean = spo2Mean) so the Dart-derived
	// baselines equal the shrinkage-blended fixture values exactly.
	seedNightHR(day.AddDate(0, 0, 0), lastRhr)
	for d := 1; d <= 30; d++ {
		seedNightHR(day.AddDate(0, 0, -d), rhrP10)
	}
	seedNightSpO2(day.AddDate(0, 0, 0), spo2Tonight)
	for d := 1; d <= 30; d++ {
		seedNightSpO2(day.AddDate(0, 0, -d), spo2Mean)
	}

	// goals: ~60% with steps samples; ~25% with sleep goal (bed/target
	// currents present → F-09 update path exercised over baselineNights[0:21])
	var goalSamples []int
	goalCurrent := 0
	var bedCur, targetCur *int
	lastAuto := int64(0)
	if rng.Intn(10) < 6 {
		n := 7 + rng.Intn(24) // 7..30 days (covers provisional/good/optimal)
		for d := 0; d < n; d++ {
			goalSamples = append(goalSamples, 4000+rng.Intn(12000))
		}
		goalCurrent = 6000 + rng.Intn(3000)
		lastAuto = past.UnixMilli()
		if rng.Intn(10) == 0 { // manual override blocks
			lastAuto = 0
			goalSamples = nil
		}
	}
	if rng.Intn(4) == 0 {
		bed := 1320
		target := 480
		bedCur, targetCur = &bed, &target
	}

	var history []int
	// Effective bed/target AFTER the sleep goal update (the Dart runs
	// maybeAutoUpdateAll BEFORE scoring, so history/today scores use the
	// UPDATED config). Mirror the engine: goals.UpdateSleep, then
	// current ?? default, overridden by the update when it fires.
	{
		var bedtimes, durations []int
		nights := baselineNights
		if len(nights) > 21 {
			nights = nights[:21]
		}
		for _, n := range nights {
			na, _ := time.ParseInLocation("2006-01-02", n.Date, time.Local)
			bt, dur, _ := nightStats(n.Segments, na, time.Local)
			bedtimes = append(bedtimes, bt)
			durations = append(durations, dur)
		}
		var lastUp *time.Time
		if lastAuto > 0 {
			t := time.UnixMilli(lastAuto)
			lastUp = &t
		}
		sl := goals.UpdateSleep(goals.SleepInput{
			BedtimeMinutes:   bedtimes,
			DurationMinutes:  durations,
			PriorBedTime:     1320,
			PriorSleepTarget: 480,
			State: goals.SleepState{
				CurrentBedTime:     bedCur,
				CurrentSleepTarget: targetCur,
				LastAutoUpdateAt:   lastUp,
			},
			Now: now,
			Cfg: goals.DefaultConfig(),
		})
		effBed := 1320
		effTarget := 480
		if bedCur != nil {
			effBed = *bedCur
		}
		if targetCur != nil {
			effTarget = *targetCur
		}
		if sl.Updated {
			effBed = *sl.NewBedTime
			effTarget = *sl.NewSleepTarget
		}
		// sleep history = scores of nights D-1..D-4 (baselineNights[0..3])
		// with the goal-effective config.
		for h := 0; h < 4; h++ {
			nightDay := day.AddDate(0, 0, -(h + 1))
			score := sleepScoreOf(nightTemplate(nightDay, chosen[h]), nightDay, effBed, effTarget)
			history = append(history, score)
		}
	}

	// Capped anchors: the Dart forNight window is degenerate ([18:00,18:00])
	// so nightlyRestingHr/nightlyAvgSpo2 find no samples → components null.
	// Mirror that by omitting the RHR/SpO2 inputs (the Go runner then also
	// skips the components).
	var lastRhrP, spo2TonightP *float64
	if anchorName != "capped_16h" {
		lastRhrP = &lastRhr
		spo2TonightP = &spo2Tonight
	}
	f := &Fixture{
		FixtureID:            fmt.Sprintf("synth_%04d", i),
		PersonID:             fmt.Sprintf("diff_person_%04d", i),
		Day:                  day.Format("2006-01-02"),
		Timezone:             time.Local.String(),
		Segments:             anchor.Segments,
		HRV:                  hrv,
		Battery:              battery,
		Steps:                steps,
		SessionKcal:          sessionKcal,
		SleepHistory:         history,
		BaselineNights:       baselineNights,
		HR:                   hrSamples,
		SpO2:                 spo2Samples,
		LastNightRhr:         lastRhrP,
		RhrBaseline:          &rhrBase,
		Spo2Tonight:          spo2TonightP,
		Spo2Baseline:         &spo2Base,
		GoalStepsCurrent:     goalCurrent,
		GoalStepSamples:      goalSamples,
		GoalPriorSteps:       7500,
		GoalMaxDailySteps:    15000,
		GoalLastAutoUpdateMs: lastAuto,
		SleepBedCurrent:      bedCur,
		SleepTargetCurrent:   targetCur,
		NowMs:                now.UnixMilli(),
	}
	return f, nil
}
