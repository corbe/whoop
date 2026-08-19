// Stress score — port of StressScoreAlgorithm (F-02).
//
// Source: lib/core/scores/stress_score.dart @ 5b1698f. HRV log-domain model:
// baseline = mean of daily averages; ln-sample-SD (clamped [0.20,0.40],
// default 0.22 for n<2); observed = 7-day linear-weighted trend; z-score
// (special case: observed >= 2x baseline → z = −0.4); sigmoid →
// score = round(clamp(12 + 83*logistic, 12, 95)).clamp(0,100).
// LOWER stress score = better (higher HRV).
package stress

import (
	"math"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/stats"
)

// Algorithm mirrors StressScoreAlgorithm (all methods pure).
type Algorithm struct {
	Cfg config.Stress
}

// New returns an Algorithm with the given config (default if zero).
func New(cfg config.Stress) *Algorithm {
	return &Algorithm{Cfg: cfg}
}

// LnRmssd mirrors lnRmssd: ln(clamp(ms, 1, inf)).
func (a *Algorithm) LnRmssd(ms float64) float64 {
	return math.Log(math.Max(1.0, ms))
}

// LnSdFromDailyMs mirrors lnSdFromDailyMs: sample stddev of ln values,
// clamped [minLnSd, maxLnSd]; defaultLnSd when n < 2.
func (a *Algorithm) LnSdFromDailyMs(dailyMs []float64) float64 {
	if len(dailyMs) < 2 {
		return a.Cfg.DefaultLnSd
	}
	lnVals := make([]float64, len(dailyMs))
	for i, v := range dailyMs {
		lnVals[i] = a.LnRmssd(v)
	}
	sd := stats.SampleStdDev(lnVals)
	return stats.Clamp(sd, a.Cfg.MinLnSd, a.Cfg.MaxLnSd)
}

// SanitizeObservedMs mirrors sanitizeObservedMs: clamp observed to
// [0.45*baseline, 1.55*baseline]; passthrough when either <= 0.
func (a *Algorithm) SanitizeObservedMs(baselineMs, observedMs float64) float64 {
	if baselineMs <= 0 || observedMs <= 0 {
		return observedMs
	}
	return stats.Clamp(observedMs, baselineMs*0.45, baselineMs*1.55)
}

// ZScore mirrors zScore. Special case FIRST: observed >= 2*baseline → −0.4.
func (a *Algorithm) ZScore(baselineMs, observedMs, baselineLnSd float64) float64 {
	if baselineMs <= 0 || observedMs <= 0 {
		return 0
	}
	if observedMs >= baselineMs*2.0 {
		return -0.4
	}
	sd := stats.Clamp(baselineLnSd, a.Cfg.MinLnSd, a.Cfg.MaxLnSd)
	z := (a.LnRmssd(baselineMs) - a.LnRmssd(observedMs)) / sd
	return stats.Clamp(z, a.Cfg.ZClampMin, a.Cfg.ZClampMax)
}

// ScoreFromZ mirrors scoreFromZ: logistic with sigmoidSteepness/midpoint,
// then clamp [minScoreWithData, 95].
func (a *Algorithm) ScoreFromZ(z float64) float64 {
	clamped := stats.Clamp(z, a.Cfg.ZClampMin, a.Cfg.ZClampMax)
	logistic := 1.0 / (1.0 + math.Exp(-a.Cfg.SigmoidSteepness*(clamped-a.Cfg.SigmoidMidpoint)))
	return stats.Clamp(a.Cfg.MinScoreWithData+a.Cfg.SigmoidSpan*logistic,
		a.Cfg.MinScoreWithData, 95.0)
}

// FromHrv mirrors fromHrv: sanitize then scoreFromZ(zScore(...)).
func (a *Algorithm) FromHrv(baselineMs, observedMs, baselineLnSd float64) float64 {
	if baselineMs <= 0 || observedMs <= 0 {
		return 0
	}
	safe := a.SanitizeObservedMs(baselineMs, observedMs)
	return a.ScoreFromZ(a.ZScore(baselineMs, safe, baselineLnSd))
}

// RollingDailyAverageMs mirrors rollingDailyAverageMs: linear weights 1..k
// over the last d days (or all), oldest→newest.
func (a *Algorithm) RollingDailyAverageMs(dailyAverages []float64) float64 {
	return stats.LinearWeightedMean(dailyAverages, a.Cfg.RollingTrendDays)
}

// TrendResult carries the service-level outputs (stress_score.dart:155-190).
type TrendResult struct {
	Score        int
	BaselineMs   float64
	BaselineLnSd float64
	TrendMs      float64
	// DownCount mirrors the service's missing-days counter:
	// minDaysRequired − n when insufficient, else 0.
	DownCount int
	// Sufficient is false when dailyAverages < minDaysRequired.
	Sufficient bool

	// Explanation intermediates (additive; the score math is unchanged).
	ObservedMs  float64 // observed after trend fallback (pre-sanitize)
	SanitizedMs float64 // clamped [0.45x, 1.55x] baseline
	Z           float64 // clamped z (or −0.4 special case)
	RawScore    float64 // pre-round scoreFromZ value
}

// Trend mirrors StressScoreService.calculate for the given daily HRV
// averages (the service derives these from raw records by local-day
// bucketing; the caller supplies them — see engine orchestration).
//
// Returns Sufficient=false (Score 0, DownCount = minDays − n) when there are
// fewer than minDaysRequired days, matching the service.
func (a *Algorithm) Trend(dailyAverages []float64) TrendResult {
	if len(dailyAverages) < a.Cfg.MinDaysRequired {
		return TrendResult{
			Score:      0,
			DownCount:  a.Cfg.MinDaysRequired - len(dailyAverages),
			Sufficient: false,
		}
	}
	baselineMs := stats.Mean(dailyAverages)
	baselineLnSd := a.LnSdFromDailyMs(dailyAverages)
	trendMs := a.RollingDailyAverageMs(dailyAverages)
	observed := trendMs
	if observed <= 0 {
		observed = dailyAverages[len(dailyAverages)-1]
	}
	sanitized := a.SanitizeObservedMs(baselineMs, observed)
	z := a.ZScore(baselineMs, sanitized, baselineLnSd)
	raw := a.ScoreFromZ(z)
	score := int(math.Round(raw))
	score = stats.ClampInt(score, 0, 100)
	return TrendResult{
		Score:        score,
		BaselineMs:   baselineMs,
		BaselineLnSd: baselineLnSd,
		TrendMs:      trendMs,
		Sufficient:   true,
		ObservedMs:   observed,
		SanitizedMs:  sanitized,
		Z:            z,
		RawScore:     raw,
	}
}

// InstantHRVMs mirrors the service's instant-HRV geometric mean: for each
// window in InstantWindowMinutes (15, 60, 180), if any samples fall within
// [now − window, now], return exp(mean(ln(samples))); else 0.
func (a *Algorithm) InstantHRVMs(samples []float64, nowMs int64, sampleTsMs []int64) float64 {
	for _, windowMin := range a.Cfg.InstantWindowMinutes {
		windowStart := nowMs - int64(windowMin)*60*1000
		var recent []float64
		for i, ts := range sampleTsMs {
			if ts >= windowStart {
				recent = append(recent, samples[i])
			}
		}
		if len(recent) == 0 {
			continue
		}
		lnSum := 0.0
		for _, v := range recent {
			lnSum += a.LnRmssd(v)
		}
		return math.Exp(lnSum / float64(len(recent)))
	}
	return 0
}
