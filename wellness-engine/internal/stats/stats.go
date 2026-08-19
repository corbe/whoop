// Statistical utilities with EXACT Dart parity.
//
// Every function here reproduces the rounding/order semantics of the Dart
// code it ports (see docs/wellness-formula-audit.md):
//   - Dart .round() = half away from zero  -> Round()
//   - Dart .toInt() on double = truncation toward zero -> Trunc()
//   - Dart ceil() -> Ceil()
//   - Dart ~/ (int division) = truncation toward zero -> Go int division
//   - clamp(x, lo, hi) with hi >= lo
package stats

import "math"

// Clamp returns x bounded to [lo, hi] (Dart num.clamp semantics).
func Clamp(x, lo, hi float64) float64 {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

// ClampInt mirrors Dart int.clamp.
func ClampInt(x, lo, hi int) int {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

// Round is Dart double.round() (half away from zero).
func Round(x float64) float64 { return math.Round(x) }

// RoundInt is Dart (x).round() cast to int.
func RoundInt(x float64) int { return int(math.Round(x)) }

// CeilInt is Dart (x).ceil() cast to int.
func CeilInt(x float64) int { return int(math.Ceil(x)) }

// TruncInt is Dart (x).toInt() (truncation toward zero).
func TruncInt(x float64) int { return int(x) }

// Mean is the simple arithmetic mean (Dart reduce/+/len). Returns 0 for empty.
func Mean(vals []float64) float64 {
	if len(vals) == 0 {
		return 0
	}
	sum := 0.0
	for _, v := range vals {
		sum += v
	}
	return sum / float64(len(vals))
}

// MeanInt is Mean over ints as float64 (Dart: int sum / int length = double).
func MeanInt(vals []int) float64 {
	if len(vals) == 0 {
		return 0
	}
	sum := 0
	for _, v := range vals {
		sum += v
	}
	return float64(sum) / float64(len(vals))
}

// MedianInt mirrors the Dart _medianInt used in sleep_stage_summary.dart:435-441
// and personalized_lifestyle_baseline.dart:598-604:
//
//	odd  -> sorted[mid]
//	even -> round((sorted[mid-1] + sorted[mid]) / 2)   // double division!
func MedianInt(vals []int) int {
	if len(vals) == 0 {
		return 0
	}
	sorted := append([]int(nil), vals...)
	sortInts(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[mid]
	}
	// Dart: ((a + b) / 2).round() — int+int, then DOUBLE division, then round.
	return RoundInt((float64(sorted[mid-1]) + float64(sorted[mid])) / 2)
}

// P10NearestRank mirrors WellnessBaselines.nightlyRestingHr
// (wellness_baselines.dart:108-110): sorted values, idx = floor(n*0.1)
// clamped to [0, n-1], returns the raw value at idx (no interpolation).
func P10NearestRank(vals []float64) (float64, bool) {
	if len(vals) == 0 {
		return 0, false
	}
	sorted := append([]float64(nil), vals...)
	sortFloats(sorted)
	idx := int(math.Floor(float64(len(sorted)) * 0.1))
	idx = ClampInt(idx, 0, len(sorted)-1)
	return sorted[idx], true
}

// SampleStdDev is the sample standard deviation (n-1 denominator), as used by
// lnSdFromDailyMs (stress_score.dart:17-26) and bedtimeBaseline
// (sleep_stage_summary.dart:386-393). Returns 0 for n <= 1.
func SampleStdDev(vals []float64) float64 {
	n := len(vals)
	if n <= 1 {
		return 0
	}
	mean := Mean(vals)
	sumSq := 0.0
	for _, v := range vals {
		d := v - mean
		sumSq += d * d
	}
	return math.Sqrt(sumSq / float64(n-1))
}

// LinearWeightedMean mirrors rollingDailyAverageMs (stress_score.dart:69-86):
// the LAST d values (or all if fewer) weighted 1..k oldest->newest:
//
//	weightedSum = Σ vals[i] * (i+1); weightTotal = Σ (i+1)
func LinearWeightedMean(vals []float64, days int) float64 {
	if len(vals) == 0 {
		return 0
	}
	slice := vals
	if len(vals) > days {
		slice = vals[len(vals)-days:]
	}
	weightedSum := 0.0
	weightTotal := 0.0
	for i, v := range slice {
		w := float64(i + 1)
		weightedSum += v * w
		weightTotal += w
	}
	return weightedSum / weightTotal
}

// LerpInt mirrors the inner lerp of scoreFatigueFromAverage
// (readiness_score.dart:68-71): round(y0 + (y1-y0)*(x-x0)/(x1-x0)), with
// x1 == x0 returning y0.
func LerpInt(x0, y0, x1, y1, x int) int {
	if x1 == x0 {
		return y0
	}
	return RoundInt(float64(y0) + (float64(y1-y0))*float64(x-x0)/float64(x1-x0))
}

// WeightedBlend mirrors ReadinessScoreAlgorithm.weightedBlend
// (readiness_score.dart:125-134): round(Σ score*weight / Σ weight).clamp(0,100);
// returns 0 when total weight <= 0.
func WeightedBlend(components []WeightedComponent) int {
	sum := 0.0
	totalWeight := 0.0
	for _, c := range components {
		sum += float64(c.Score) * c.Weight
		totalWeight += c.Weight
	}
	if totalWeight <= 0 {
		return 0
	}
	return ClampInt(RoundInt(sum/totalWeight), 0, 100)
}

// WeightedComponent is one (score, weight) pair for WeightedBlend.
type WeightedComponent struct {
	Score  int
	Weight float64
}

func sortInts(v []int) {
	for i := 1; i < len(v); i++ {
		for j := i; j > 0 && v[j] < v[j-1]; j-- {
			v[j], v[j-1] = v[j-1], v[j]
		}
	}
}

func sortFloats(v []float64) {
	for i := 1; i < len(v); i++ {
		for j := i; j > 0 && v[j] < v[j-1]; j-- {
			v[j], v[j-1] = v[j-1], v[j]
		}
	}
}
