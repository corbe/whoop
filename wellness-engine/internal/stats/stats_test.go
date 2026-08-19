package stats

import (
	"math"
	"testing"
)

func TestClamp(t *testing.T) {
	cases := []struct{ x, lo, hi, want float64 }{
		{5, 0, 10, 5}, {-1, 0, 10, 0}, {11, 0, 10, 10},
	}
	for _, c := range cases {
		if got := Clamp(c.x, c.lo, c.hi); got != c.want {
			t.Errorf("Clamp(%v,%v,%v)=%v want %v", c.x, c.lo, c.hi, got, c.want)
		}
	}
}

func TestRoundSemantics(t *testing.T) {
	// Dart .round() = half away from zero.
	if got := Round(2.5); got != 3 {
		t.Errorf("Round(2.5)=%v want 3", got)
	}
	if got := Round(-2.5); got != -3 {
		t.Errorf("Round(-2.5)=%v want -3", got)
	}
	if got := TruncInt(34.9); got != 34 {
		t.Errorf("TruncInt(34.9)=%v want 34 (Dart toInt truncates)", got)
	}
	if got := CeilInt(1.2); got != 2 {
		t.Errorf("CeilInt(1.2)=%v want 2", got)
	}
}

func TestMedianInt(t *testing.T) {
	// odd
	if got := MedianInt([]int{3, 1, 2}); got != 2 {
		t.Errorf("odd: got %v want 2", got)
	}
	// even: (5+6)/2 = 5.5 -> round -> 6 (Dart double division then round)
	if got := MedianInt([]int{1, 5, 6, 9}); got != 6 {
		t.Errorf("even: got %v want 6", got)
	}
	// even: (4+6)/2 = 5.0 -> 5
	if got := MedianInt([]int{1, 4, 6, 9}); got != 5 {
		t.Errorf("even2: got %v want 5", got)
	}
	if got := MedianInt(nil); got != 0 {
		t.Errorf("empty: got %v want 0", got)
	}
}

func TestP10NearestRank(t *testing.T) {
	// n=10: idx = floor(1.0) = 1 -> sorted[1]
	got, ok := P10NearestRank([]float64{80, 70, 60, 50, 40, 30, 20, 10, 90, 100})
	if !ok || got != 20 {
		t.Errorf("n=10: got %v ok=%v want 20", got, ok)
	}
	// n=1: idx = floor(0.1) = 0 -> sorted[0]
	got, ok = P10NearestRank([]float64{77})
	if !ok || got != 77 {
		t.Errorf("n=1: got %v ok=%v want 77", got, ok)
	}
	if _, ok := P10NearestRank(nil); ok {
		t.Error("empty should report not-ok")
	}
}

func TestSampleStdDev(t *testing.T) {
	if got := SampleStdDev([]float64{42.0}); got != 0 {
		t.Errorf("n=1: got %v want 0", got)
	}
	// stress lnSd: sample stddev over LN values of 40..70 step 1.5 (n=21);
	// the Dart code clamps to [0.20, 0.40] — raw must be < 0.20.
	vals := make([]float64, 21)
	for i := range vals {
		vals[i] = math.Log(40 + float64(i)*1.5)
	}
	got := SampleStdDev(vals)
	if got >= 0.20 {
		t.Errorf("ln-series stddev should be < 0.20, got %v", got)
	}
	// sanity: stddev of {1,2,3} = 1
	if got := SampleStdDev([]float64{1, 2, 3}); math.Abs(got-1) > 1e-12 {
		t.Errorf("stddev(1,2,3)=%v want 1", got)
	}
}

func TestLinearWeightedMean(t *testing.T) {
	// mirror the oracle trend: last 7 of 40+1.5i = 61,62.5,64,65.5,67,68.5,70
	vals := make([]float64, 21)
	for i := range vals {
		vals[i] = 40 + float64(i)*1.5
	}
	if got := LinearWeightedMean(vals, 7); got != 67.0 {
		t.Errorf("trend: got %v want 67.0", got)
	}
	if got := LinearWeightedMean(nil, 7); got != 0 {
		t.Errorf("empty: got %v want 0", got)
	}
}

func TestLerpInt(t *testing.T) {
	// lerp(50,38,65,65,50) = 38; lerp(50,38,65,65,65) = 65
	if got := LerpInt(50, 38, 65, 65, 50); got != 38 {
		t.Errorf("lerp left: got %v want 38", got)
	}
	if got := LerpInt(50, 38, 65, 65, 65); got != 65 {
		t.Errorf("lerp right: got %v want 65", got)
	}
	// x0==x1 guard
	if got := LerpInt(10, 5, 10, 9, 10); got != 5 {
		t.Errorf("x0==x1: got %v want 5", got)
	}
	// mid: lerp(40,25,50,38,45) = 25 + 13*5/10 = 31.5 -> 32
	if got := LerpInt(40, 25, 50, 38, 45); got != 32 {
		t.Errorf("lerp mid: got %v want 32", got)
	}
}

func TestWeightedBlend(t *testing.T) {
	// oracle readiness_blend_all: (80,.35)(70,.25)(90,.15)(100,.10)(85,.15) -> 82
	got := WeightedBlend([]WeightedComponent{
		{80, 0.35}, {70, 0.25}, {90, 0.15}, {100, 0.10}, {85, 0.15},
	})
	if got != 82 {
		t.Errorf("blend all: got %v want 82", got)
	}
	// oracle readiness_blend_missing_optional: (80,.35)(70,.25) -> 76
	got = WeightedBlend([]WeightedComponent{{80, 0.35}, {70, 0.25}})
	if got != 76 {
		t.Errorf("blend partial: got %v want 76", got)
	}
	if got := WeightedBlend(nil); got != 0 {
		t.Errorf("empty: got %v want 0", got)
	}
}
