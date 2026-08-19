package baseline

import (
	"math"
	"testing"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/golden"
)

func TestGoldenBaselineOracle(t *testing.T) {
	oracle, err := golden.Load()
	if err != nil {
		t.Fatal(err)
	}

	// confidence ladder
	{
		entry := oracle["baseline_confidence"].(map[string]any)
		input := entry["input"].(map[string]any)["sampleCounts"].([]any)
		output := entry["output"].(map[string]any)
		for _, nv := range input {
			n := int(nv.(float64))
			got := ConfidenceFromCount(n).String()
			want := output[itoa(n)].(string)
			if got != want {
				t.Errorf("confidence(%d): got %s want %s", n, got, want)
			}
		}
	}

	// shrinkage blend: obs 72, prior 65, n [0,5,15,30,60]
	{
		entry := oracle["baseline_shrinkage"].(map[string]any)
		input := entry["input"].(map[string]any)["sampleCounts"].([]any)
		output := entry["output"].(map[string]any)
		for _, nv := range input {
			n := int(nv.(float64))
			got := ShrinkageBlend(72.0, 65.0, n, 30)
			want := output[itoa(n)].(float64)
			if math.Abs(got-want) > 1e-12 {
				t.Errorf("shrinkage(%d): got %v want %v", n, got, want)
			}
		}
	}
}

func TestRollingRestingHr(t *testing.T) {
	cfg := config.DefaultBaseline()
	// empty → prior 65, none
	b := RollingRestingHr(nil, cfg)
	if b.Value != 65 || b.Confidence != ConfidenceNone || b.SampleCount != 0 {
		t.Errorf("empty: got %+v", b)
	}
	// 20 nightly P10s around 72 → median 72, w=20/30, blend = 72*2/3+65/3
	nightly := make([]float64, 20)
	for i := range nightly {
		nightly[i] = 72.0
	}
	b = RollingRestingHr(nightly, cfg)
	want := 72.0*20.0/30.0 + 65.0*10.0/30.0
	if math.Abs(b.Value-want) > 1e-9 {
		t.Errorf("value: got %v want %v", b.Value, want)
	}
	if b.Confidence != ConfidenceGood {
		t.Errorf("confidence: got %v want good", b.Confidence)
	}
	// even-count median: values 60, 80 → observed 70; shrinkage w=2/30
	// → 70*2/30 + 65*28/30 = 65.3333...
	b = RollingRestingHr([]float64{80, 60}, cfg)
	if math.Abs(b.Value-65.33333333333333) > 1e-9 {
		t.Errorf("median even+shrinkage: got %v want 65.3333", b.Value)
	}
}

func TestRollingNightSpo2(t *testing.T) {
	cfg := config.DefaultBaseline()
	b := RollingNightSpo2(nil, cfg)
	if b.Value != 96 || b.Confidence != ConfidenceNone {
		t.Errorf("empty: got %+v", b)
	}
	// 30 nightly means of 97 → observed 97, w=1 → 97
	nightly := make([]float64, 30)
	for i := range nightly {
		nightly[i] = 97.0
	}
	b = RollingNightSpo2(nightly, cfg)
	if math.Abs(b.Value-97.0) > 1e-9 {
		t.Errorf("value: got %v want 97", b.Value)
	}
	if b.Confidence != ConfidenceOptimal {
		t.Errorf("confidence: got %v want optimal", b.Confidence)
	}
}

func TestNightlyRestingHrP10(t *testing.T) {
	// 10 samples → idx = floor(1.0) = 1 → sorted[1] = 65
	got, ok := NightlyRestingHr([]float64{80, 70, 62, 65, 68, 75, 72, 78, 85, 90})
	if !ok || got != 65 {
		t.Errorf("p10: got %v ok=%v want 65", got, ok)
	}
}

func TestDailyStepsPeak(t *testing.T) {
	ts := time.Date(2026, 8, 10, 12, 0, 0, 0, time.UTC)
	records := []domain.Measurement{
		{Value: 100, Timestamp: ts, Device: domain.DeviceAPI},
		{Value: 900, Timestamp: ts.Add(time.Minute), Device: domain.DeviceBracelet},
		{Value: 400, Timestamp: ts.Add(2 * time.Minute), Device: domain.DeviceBracelet},
	}
	if got := DailyStepsPeak(records); got != 900 {
		t.Errorf("peak: got %d want 900", got)
	}
	if got := DailyStepsPeak(nil); got != 0 {
		t.Errorf("empty: got %d want 0", got)
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var buf [8]byte
	pos := len(buf)
	for i > 0 {
		pos--
		buf[pos] = byte('0' + i%10)
		i /= 10
	}
	return string(buf[pos:])
}
