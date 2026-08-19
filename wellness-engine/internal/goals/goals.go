// Adaptive goal auto-update — port of PersonalizedLifestyleBaseline
// (F-08 steps goal, F-09 sleep config).
//
// Source: lib/core/scores/personalized_lifestyle_baseline.dart @ 5b1698f.
// Verified against the machine-executed Dart oracle
// (docs/golden/oracle-goals.json, produced by test/goal_oracle_test.dart with
// real Isar + SharedPreferences).
//
// CRITICAL comment-vs-code discrepancy (caught by the oracle, case goal_s5):
// the calibration comment says "Auto-update só a partir de `good` (≥14
// amostras)", but minConfidenceForAutoUpdate = 2 = BaselineConfidence.
// PROVISIONAL.index — updates ARE allowed from 7+ sample days. The code wins.
//
// The Dart implementation reads wall-clock (cooldown/manual-override prefs)
// and persists through Isar/SharedPreferences; this package is PURE:
// Now is an explicit input and persistence is the caller's concern.
package goals

import (
	"math"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/baseline"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/stats"
)

// Config mirrors PersonalizedBaselineCalibration (score_calibration.dart:169-205).
type Config struct {
	StepsWindowDays             int     // 30
	SleepWindowDays             int     // 21
	AutoUpdateCooldownDays      int     // 7
	ManualOverrideBlockDays     int     // 30
	MaxStepsChangeFraction      float64 // 0.35
	MaxBedtimeChangeMinutes     int     // 30
	MaxSleepTargetChangeMinutes int     // 30
	// MinConfidenceForAutoUpdate is the BaselineConfidence INDEX threshold
	// (2 = provisional). The Dart default is 2 — NOT good(3), despite the
	// calibration comment (see header).
	MinConfidenceForAutoUpdate int
	BaseDailySteps             int // 7000
	MinDailySteps              int // 3000
	MaxDailySteps              int // 15000
	DefaultBedTimeMinutes      int // 1320
	DefaultSleepTargetMinutes  int // 480
	MinSleepTargetMinutes      int // 300
	MaxSleepTargetMinutes      int // 600
}

// DefaultConfig mirrors ScoreCalibration.current.personalized.
func DefaultConfig() Config {
	return Config{
		StepsWindowDays:             30,
		SleepWindowDays:             21,
		AutoUpdateCooldownDays:      7,
		ManualOverrideBlockDays:     30,
		MaxStepsChangeFraction:      0.35,
		MaxBedtimeChangeMinutes:     30,
		MaxSleepTargetChangeMinutes: 30,
		MinConfidenceForAutoUpdate:  2, // provisional.index
		BaseDailySteps:              7000,
		MinDailySteps:               3000,
		MaxDailySteps:               15000,
		DefaultBedTimeMinutes:       1320,
		DefaultSleepTargetMinutes:   480,
		MinSleepTargetMinutes:       300,
		MaxSleepTargetMinutes:       600,
	}
}

// Reason explains why an update did or did not happen.
type Reason string

const (
	ReasonApplied                  Reason = "applied"
	ReasonInsufficientConfidence   Reason = "insufficient_confidence"
	ReasonManualOverrideActive     Reason = "manual_override_active"
	ReasonCooldownActive           Reason = "cooldown_active"
	ReasonGoalUnchanged            Reason = "goal_unchanged"
	ReasonEqualsPriorLowConfidence Reason = "equals_prior_low_confidence"
)

// ── Steps goal (F-08) ──────────────────────────────────────────────────────

// StepsState is the persisted goal state (Parameter.limitMax + prefs).
type StepsState struct {
	CurrentGoal      int        // 0 = none (new user; gets seeded with prior)
	LastAutoUpdateAt *time.Time // nil = never updated
	ManualOverrideAt *time.Time // nil = no manual override
}

// StepsInput is everything UpdateSteps needs (no I/O inside).
type StepsInput struct {
	// DailySamples are the daily step PEAKS for D-1..D-30 (0/absent days are
	// not counted, mirroring `if (steps > 0) samples.add(steps)`).
	DailySamples []int
	// Prior is the demographic prior (PriorDailySteps) used as the shrinkage
	// target and the new-user seed.
	Prior int
	// MaxDailySteps is maxDailyStepsForAge (12000 if age>=65 else 15000).
	MaxDailySteps int
	State         StepsState
	Now           time.Time
	Cfg           Config
}

// StepsResult mirrors computeStepsBaseline + _maybeAutoUpdateStepsGoal.
type StepsResult struct {
	// Baseline value (shrinkage-blended median; prior when no samples).
	Baseline      baseline.NumericBaseline
	Observed      *int // median of samples; nil when none
	Updated       bool
	NewGoal       *int // set when Updated
	EffectiveGoal int  // goal the app persists after this operation
	Reason        Reason
}

// UpdateSteps mirrors PersonalizedLifestyleBaseline._maybeAutoUpdateStepsGoal
// including computeStepsBaseline intermediates.
func UpdateSteps(in StepsInput) StepsResult {
	cfg := in.Cfg
	if cfg.StepsWindowDays <= 0 {
		cfg.StepsWindowDays = 30
	}
	if cfg.MinDailySteps <= 0 {
		cfg.MinDailySteps = 3000
	}
	maxSteps := in.MaxDailySteps
	if maxSteps <= 0 {
		maxSteps = cfg.MaxDailySteps
	}

	// computeStepsBaseline
	var samples []int
	for _, s := range in.DailySamples {
		if s > 0 {
			samples = append(samples, s)
		}
	}
	priorF := float64(in.Prior)
	var observed *int
	var b baseline.NumericBaseline
	if len(samples) == 0 {
		b = baseline.NumericBaseline{Value: priorF, Confidence: baseline.ConfidenceNone}
	} else {
		med := stats.MedianInt(samples)
		observed = &med
		b = baseline.NumericBaseline{
			Value:       baseline.ShrinkageBlend(float64(med), priorF, len(samples), cfg.StepsWindowDays),
			SampleCount: len(samples),
			Confidence:  baseline.ConfidenceFromCount(len(samples)),
		}
	}

	res := StepsResult{Baseline: b, Observed: observed, EffectiveGoal: in.State.CurrentGoal}

	// guardrails (order matters — mirrors the Dart code)
	if int(b.Confidence) < cfg.MinConfidenceForAutoUpdate {
		res.Reason = ReasonInsufficientConfidence
		if in.State.CurrentGoal <= 0 {
			res.EffectiveGoal = in.Prior // ensureSeededDefaults
		}
		return res
	}
	if overrideActive(in.State.ManualOverrideAt, cfg.ManualOverrideBlockDays, in.Now) {
		res.Reason = ReasonManualOverrideActive
		return res
	}
	if cooldownActive(in.State.LastAutoUpdateAt, cfg.AutoUpdateCooldownDays, in.Now) {
		res.Reason = ReasonCooldownActive
		return res
	}

	newGoal := roundStepsToNearest5(stats.RoundInt(b.Value))
	newGoal = stats.ClampInt(newGoal, cfg.MinDailySteps, maxSteps)

	if in.State.CurrentGoal > 0 {
		maxDelta := stats.RoundInt(float64(in.State.CurrentGoal) * cfg.MaxStepsChangeFraction)
		if absInt(newGoal-in.State.CurrentGoal) > maxDelta {
			if newGoal > in.State.CurrentGoal {
				newGoal = in.State.CurrentGoal + maxDelta
			} else {
				newGoal = in.State.CurrentGoal - maxDelta
			}
			newGoal = roundStepsToNearest5(newGoal)
		}
		if newGoal == in.State.CurrentGoal {
			res.Reason = ReasonGoalUnchanged
			res.EffectiveGoal = in.State.CurrentGoal
			return res
		}
	}

	// demo-prior guard: block no-op updates at low confidence
	if newGoal == in.Prior && int(b.Confidence) < int(baseline.ConfidenceGood) {
		res.Reason = ReasonEqualsPriorLowConfidence
		if in.State.CurrentGoal > 0 {
			res.EffectiveGoal = in.State.CurrentGoal
		} else {
			res.EffectiveGoal = in.Prior
		}
		return res
	}

	res.Updated = true
	res.NewGoal = &newGoal
	res.EffectiveGoal = newGoal
	res.Reason = ReasonApplied
	return res
}

// ── Sleep config (F-09) ────────────────────────────────────────────────────

// SleepState is the persisted sleep config (prefs).
type SleepState struct {
	CurrentBedTime     *int // nil = none (seeded with prior)
	CurrentSleepTarget *int
	LastAutoUpdateAt   *time.Time
	ManualOverrideAt   *time.Time
}

// SleepInput is everything UpdateSleep needs.
type SleepInput struct {
	// BedtimeMinutes are the per-night normalized bedtimes (minutes < 720
	// already shifted +1440) for D-1..D-21.
	BedtimeMinutes []int
	// DurationMinutes are the per-night effective sleep minutes (rounded)
	// for D-1..D-21.
	DurationMinutes  []int
	PriorBedTime     int
	PriorSleepTarget int
	State            SleepState
	Now              time.Time
	Cfg              Config
}

// SleepResult mirrors computeSleepBaselines + _maybeAutoUpdateSleepConfig.
type SleepResult struct {
	BedTimeMinutes       int // blended, quarter-hour rounded (baseline output)
	SleepTargetMinutes   int // blended, quarter-hour rounded (baseline output)
	BedtimeStdDevMinutes float64
	SampleCount          int
	Confidence           baseline.Confidence
	Updated              bool
	NewBedTime           *int // set when Updated
	NewSleepTarget       *int // set when Updated (value returned even if equal)
	Reason               Reason
}

// UpdateSleep mirrors PersonalizedLifestyleBaseline._maybeAutoUpdateSleepConfig
// including computeSleepBaselines intermediates.
func UpdateSleep(in SleepInput) SleepResult {
	cfg := in.Cfg
	if cfg.SleepWindowDays <= 0 {
		cfg.SleepWindowDays = 21
	}

	// schedule stats: median bedtime + sample stddev (bedtimeBaseline).
	// Dart parity: bedtimeBaseline skips empty nights; the harness encodes
	// empty nights as bed 0, so filter them out (a real bedtime normalizes
	// to 1440 at midnight — 0 never occurs legitimately).
	var beds []int
	for _, n := range in.BedtimeMinutes {
		if n > 0 {
			beds = append(beds, n)
		}
	}
	var bedObserved *int
	if len(beds) > 0 {
		med := stats.MedianInt(beds)
		bedObserved = &med
	}
	stddev := 0.0
	if len(beds) > 1 {
		median := stats.MedianInt(beds)
		sumSq := 0.0
		for _, n := range beds {
			d := float64(n - median)
			sumSq += d * d
		}
		stddev = math.Sqrt(sumSq / float64(len(beds)-1))
	}

	// duration baseline: median of rounded minutes (personalizedSleepDurationBaseline)
	var durObserved *int
	durCount := 0
	for _, m := range in.DurationMinutes {
		if m > 0 {
			durCount++
		}
	}
	if durCount > 0 {
		var vals []int
		for _, m := range in.DurationMinutes {
			if m > 0 {
				vals = append(vals, m)
			}
		}
		med := stats.MedianInt(vals)
		durObserved = &med
	}

	sampleCount := durCount
	if sampleCount <= 0 {
		sampleCount = len(beds)
	}
	confidence := baseline.ConfidenceFromCount(sampleCount)

	priorBedF := float64(in.PriorBedTime)
	priorSleepF := float64(in.PriorSleepTarget)
	bedBlended := priorBedF
	if bedObserved != nil {
		bedBlended = baseline.ShrinkageBlend(float64(*bedObserved), priorBedF, len(beds), cfg.SleepWindowDays)
	}
	sleepBlended := priorSleepF
	if durObserved != nil {
		sleepBlended = baseline.ShrinkageBlend(float64(*durObserved), priorSleepF, durCount, cfg.SleepWindowDays)
	}

	newBed := roundBedTimeToQuarterHour(stats.RoundInt(bedBlended))
	newTarget := roundSleepTargetToQuarterHour(stats.RoundInt(sleepBlended), cfg)

	res := SleepResult{
		BedTimeMinutes:       newBed,
		SleepTargetMinutes:   newTarget,
		BedtimeStdDevMinutes: stddev,
		SampleCount:          sampleCount,
		Confidence:           confidence,
	}

	// guardrails
	if int(confidence) < cfg.MinConfidenceForAutoUpdate {
		res.Reason = ReasonInsufficientConfidence
		return res
	}
	if overrideActive(in.State.ManualOverrideAt, cfg.ManualOverrideBlockDays, in.Now) {
		res.Reason = ReasonManualOverrideActive
		return res
	}
	if cooldownActive(in.State.LastAutoUpdateAt, cfg.AutoUpdateCooldownDays, in.Now) {
		res.Reason = ReasonCooldownActive
		return res
	}

	// Dart parity: maybeAutoUpdateAll runs ensureSeededDefaults BEFORE the
	// update, so the "current" config is NEVER null (seeded to the demo
	// priors). Mirror that: nil current = the engine defaults.
	curBed := cfg.DefaultBedTimeMinutes
	if in.State.CurrentBedTime != nil {
		curBed = *in.State.CurrentBedTime
	}
	curTgt := cfg.DefaultSleepTargetMinutes
	if in.State.CurrentSleepTarget != nil {
		curTgt = *in.State.CurrentSleepTarget
	}
	if delta := absInt(newBed - curBed); delta > cfg.MaxBedtimeChangeMinutes {
		if newBed > curBed {
			newBed = curBed + cfg.MaxBedtimeChangeMinutes
		} else {
			newBed = curBed - cfg.MaxBedtimeChangeMinutes
		}
	}
	if delta := absInt(newTarget - curTgt); delta > cfg.MaxSleepTargetChangeMinutes {
		if newTarget > curTgt {
			newTarget = curTgt + cfg.MaxSleepTargetChangeMinutes
		} else {
			newTarget = curTgt - cfg.MaxSleepTargetChangeMinutes
		}
	}
	newBed = roundBedTimeToQuarterHour(newBed)
	newTarget = roundSleepTargetToQuarterHour(newTarget, cfg)

	unchanged := curBed == newBed && curTgt == newTarget
	if unchanged {
		res.Reason = ReasonGoalUnchanged
		return res
	}

	res.Updated = true
	res.NewBedTime = &newBed
	res.NewSleepTarget = &newTarget
	res.Reason = ReasonApplied
	return res
}

// ── helpers (Dart parity) ──────────────────────────────────────────────────

// roundStepsToNearest5 mirrors roundStepsToNearest5 (<=0 → 0).
func roundStepsToNearest5(steps int) int {
	if steps <= 0 {
		return 0
	}
	return stats.RoundInt(float64(steps)/5) * 5
}

// roundBedTimeToQuarterHour mirrors _roundBedTimeToQuarterHour (clamp 0..1425).
func roundBedTimeToQuarterHour(minutes int) int {
	rounded := stats.RoundInt(float64(minutes)/15) * 15
	return stats.ClampInt(rounded, 0, 1425)
}

// roundSleepTargetToQuarterHour mirrors _roundSleepTargetToQuarterHour
// (clamp [minSleepTarget, maxSleepTarget]).
func roundSleepTargetToQuarterHour(minutes int, cfg Config) int {
	rounded := stats.RoundInt(float64(minutes)/15) * 15
	return stats.ClampInt(rounded, cfg.MinSleepTargetMinutes, cfg.MaxSleepTargetMinutes)
}

// overrideActive mirrors _isManualOverrideActive: now − mark < blockDays.
func overrideActive(mark *time.Time, blockDays int, now time.Time) bool {
	if mark == nil {
		return false
	}
	return now.Sub(*mark) < time.Duration(blockDays)*24*time.Hour
}

// cooldownActive mirrors _isCooldownActive: now − last < cooldownDays.
func cooldownActive(last *time.Time, cooldownDays int, now time.Time) bool {
	if last == nil {
		return false
	}
	return now.Sub(*last) < time.Duration(cooldownDays)*24*time.Hour
}

func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}
