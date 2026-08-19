// Baselines — port of WellnessBaselines (F-05/F-06/F-07).
//
// Source: lib/core/scores/wellness_baselines.dart @ 5b1698f.
// DB access stays outside this package: callers collect the per-night values
// (nightly RHR P10s, nightly SpO2 means, daily steps) and call the pure
// functions here (rolling median/mean + shrinkage + confidence).
package baseline

import (
	"sort"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/stats"
)

// Confidence mirrors BaselineConfidence.
type Confidence int

const (
	ConfidenceNone        Confidence = iota // 0 samples
	ConfidenceEarly                         // 1–6
	ConfidenceProvisional                   // 7–13
	ConfidenceGood                          // 14–29
	ConfidenceOptimal                       // 30+
)

func (c Confidence) String() string {
	switch c {
	case ConfidenceNone:
		return "none"
	case ConfidenceEarly:
		return "early"
	case ConfidenceProvisional:
		return "provisional"
	case ConfidenceGood:
		return "good"
	case ConfidenceOptimal:
		return "optimal"
	}
	return "unknown"
}

// ConfidenceFromCount mirrors confidenceFromCount (wellness_baselines.dart:27-33).
func ConfidenceFromCount(sampleCount int) Confidence {
	switch {
	case sampleCount >= 30:
		return ConfidenceOptimal
	case sampleCount >= 14:
		return ConfidenceGood
	case sampleCount >= 7:
		return ConfidenceProvisional
	case sampleCount >= 1:
		return ConfidenceEarly
	}
	return ConfidenceNone
}

// ShrinkageBlend mirrors shrinkageBlend (wellness_baselines.dart:35-44):
// w = clamp(n/optimalDays, 0, 1); w*observed + (1-w)*prior; n <= 0 → prior.
func ShrinkageBlend(observed, prior float64, sampleCount int, optimalDays int) float64 {
	if sampleCount <= 0 {
		return prior
	}
	w := stats.Clamp(float64(sampleCount)/float64(optimalDays), 0.0, 1.0)
	return w*observed + (1.0-w)*prior
}

// NumericBaseline mirrors the NumericBaseline record.
type NumericBaseline struct {
	Value       float64
	SampleCount int
	Confidence  Confidence
}

// NightlyRestingHr mirrors nightlyRestingHr's P10 computation
// (wellness_baselines.dart:108-110): caller supplies HR samples within the
// sleep window, already filtered 30 < hr < 220.
func NightlyRestingHr(hrSamples []float64) (float64, bool) {
	return stats.P10NearestRank(hrSamples)
}

// RollingRestingHr mirrors rollingRestingHr (wellness_baselines.dart:113-151):
// nightly = per-night P10s for D-1..D-window; observed = MEDIAN;
// blended = shrinkageBlend(observed, prior, n, window). Empty → prior/none.
func RollingRestingHr(nightlyP10s []float64, cfg config.Baseline) NumericBaseline {
	if len(nightlyP10s) == 0 {
		return NumericBaseline{Value: cfg.PriorRestingHrBpm, Confidence: ConfidenceNone}
	}
	sorted := append([]float64(nil), nightlyP10s...)
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	var observed float64
	if len(sorted)%2 == 1 {
		observed = sorted[mid]
	} else {
		observed = (sorted[mid-1] + sorted[mid]) / 2
	}
	return NumericBaseline{
		Value:       ShrinkageBlend(observed, cfg.PriorRestingHrBpm, len(nightlyP10s), cfg.WindowDays),
		SampleCount: len(nightlyP10s),
		Confidence:  ConfidenceFromCount(len(nightlyP10s)),
	}
}

// RollingNightSpo2 mirrors rollingNightSpo2 (wellness_baselines.dart:166-200):
// observed = MEAN of nightly means; blended via shrinkage vs prior 96.
func RollingNightSpo2(nightlyMeans []float64, cfg config.Baseline) NumericBaseline {
	if len(nightlyMeans) == 0 {
		return NumericBaseline{Value: cfg.PriorNightSpo2Pct, Confidence: ConfidenceNone}
	}
	observed := stats.Mean(nightlyMeans)
	return NumericBaseline{
		Value:       ShrinkageBlend(observed, cfg.PriorNightSpo2Pct, len(nightlyMeans), cfg.WindowDays),
		SampleCount: len(nightlyMeans),
		Confidence:  ConfidenceFromCount(len(nightlyMeans)),
	}
}

// DailyStepsPeak mirrors WellnessBaselines.dailySteps (wellness_baselines.dart:55-83):
// PEAK of the day's records (BRACELET preferred), int-truncated.
func DailyStepsPeak(records []domain.Measurement) int {
	if len(records) == 0 {
		return 0
	}
	var bracelet []domain.Measurement
	for _, r := range records {
		if r.Device == domain.DeviceBracelet {
			bracelet = append(bracelet, r)
		}
	}
	preferred := bracelet
	if len(preferred) == 0 {
		preferred = records
	}
	sort.Slice(preferred, func(i, j int) bool { return preferred[i].Timestamp.Before(preferred[j].Timestamp) })
	peak := 0.0
	for _, r := range preferred {
		if r.Value > peak {
			peak = r.Value
		}
	}
	return int(peak)
}
