package sleep

import (
	"math"
	"testing"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/golden"
)

// Golden tests vs the machine-executed Dart oracle (docs/golden/oracle.json,
// section A.1 — sleep cases). The harness that produced the oracle built
// NightSummaries from (startMinuteOfDay, sleepingMinutes, pctRem/pctDeep/
// pctLight); we rebuild the same summaries and assert the score + analysis
// codes match EXACTLY.
func TestGoldenSleepOracle(t *testing.T) {
	oracle, err := golden.Load()
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.DefaultSleep()

	// cases where the summary is constructed from percentages
	for name, raw := range oracle {
		if len(name) < 6 || name[:6] != "sleep_" {
			continue
		}
		entry, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		input, ok := entry["input"].(map[string]any)
		if !ok {
			t.Fatalf("%s: input missing", name)
		}
		out, ok := entry["output"].(map[string]any)
		if !ok {
			t.Fatalf("%s: output missing", name)
		}
		bed := int(num(t, input, "bedTimeMinutes"))
		target := int(num(t, input, "sleepTargetMinutes"))

		var summary domain.NightSummary
		if empty, _ := input["empty"].(bool); empty {
			summary = domain.NightSummary{}
		} else {
			startMin := int(num(t, input, "startMinuteOfDay"))
			sleepingMin := int(num(t, input, "sleepingMinutes"))
			pctRem := num(t, input, "pctRem")
			pctDeep := num(t, input, "pctDeep")
			pctLight := num(t, input, "pctLight")
			battery := false
			if b, ok := input["batteryDepleted"].(bool); ok {
				battery = b
			}
			summary = summaryFromPcts(startMin, sleepingMin, pctRem, pctDeep, pctLight, battery)
		}
		res := Compute(summary, bed, target, cfg)

		wantScore := int(num(t, out, "sleepScore"))
		if res.Score != wantScore {
			t.Errorf("%s: score got %d want %d", name, res.Score, wantScore)
		}
		if wantBattery, _ := out["bateriaZerada"].(bool); res.BateriaZerada != wantBattery {
			t.Errorf("%s: bateriaZerada got %v want %v", name, res.BateriaZerada, wantBattery)
		}
		if wantMsg1, ok := out["sleepAnalysisMsg1"].(float64); ok {
			if int(wantMsg1) != res.Msg1 {
				t.Errorf("%s: msg1 got %d want %d", name, res.Msg1, int(wantMsg1))
			}
			if int(num(t, out, "sleepAnalysisMsg2")) != res.Msg2 {
				t.Errorf("%s: msg2 got %d want %d", name, res.Msg2, int(num(t, out, "sleepAnalysisMsg2")))
			}
			if int(num(t, out, "sleepAnalysisMsg3")) != res.Msg3 {
				t.Errorf("%s: msg3 got %d want %d", name, res.Msg3, int(num(t, out, "sleepAnalysisMsg3")))
			}
		}
		// pct parity (float artifact included) — only when the oracle
		// recorded them (empty/battery cases return early in the Dart code).
		if !summary.IsEmpty() {
			if _, ok := out["pctRem"]; ok {
				assertFloat(t, name+".pctRem", res.PctRem, num(t, out, "pctRem"))
				assertFloat(t, name+".pctDeep", res.PctDeep, num(t, out, "pctDeep"))
				assertFloat(t, name+".pctLight", res.PctLight, num(t, out, "pctLight"))
				assertFloat(t, name+".sleepingMs", float64(res.SleepingMs), num(t, out, "sleepingMs"))
			}
		}
	}
}

// summaryFromPcts mirrors the oracle harness night() builder.
func summaryFromPcts(startMinuteOfDay, sleepingMinutes int, pctRem, pctDeep, pctLight float64, battery bool) domain.NightSummary {
	sleepingMs := int64(sleepingMinutes) * 60000
	rem := int64(math.Round(float64(sleepingMs) * pctRem / 100))
	deep := int64(math.Round(float64(sleepingMs) * pctDeep / 100))
	light := int64(math.Round(float64(sleepingMs) * pctLight / 100))
	nap := sleepingMs - rem - deep - light
	start := time.Date(2026, 8, 10, startMinuteOfDay/60, startMinuteOfDay%60, 0, 0, time.Local)
	return domain.NightSummary{
		StartMs:         start.UnixMilli(),
		EndMs:           time.Date(2026, 8, 10, 7, 30, 0, 0, time.Local).UnixMilli(),
		DurationMs:      sleepingMs,
		RemMs:           rem,
		NapMs:           nap,
		LightMs:         light,
		DeepMs:          deep,
		BatteryDepleted: battery,
	}
}

func num(t *testing.T, m map[string]any, key string) float64 {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("oracle field %q missing", key)
	}
	switch n := v.(type) {
	case float64:
		return n
	case int:
		return float64(n)
	}
	t.Fatalf("oracle field %q not numeric: %T", key, v)
	return 0
}

func assertFloat(t *testing.T, name string, got, want float64) {
	t.Helper()
	if math.Abs(got-want) > 1e-9*math.Max(1, math.Abs(want)) {
		t.Errorf("%s: got %v want %v", name, got, want)
	}
}
