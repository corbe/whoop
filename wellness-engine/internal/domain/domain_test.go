package domain

import (
	"testing"
	"time"
)

func TestValidRanges(t *testing.T) {
	cases := []struct {
		name string
		got  bool
		want bool
	}{
		{"hr 30 rejected", ValidHeartRate(30), false},
		{"hr 31 ok", ValidHeartRate(31), true},
		{"hr 219 ok", ValidHeartRate(219), true},
		{"hr 220 rejected", ValidHeartRate(220), false},
		{"hrv 0 rejected", ValidHRV(0), false},
		{"hrv 0.5 ok", ValidHRV(0.5), true},
		{"spo2 70 accepted in window", ValidSpO2Window(70), true},
		{"spo2 69.9 rejected", ValidSpO2Window(69.9), false},
		{"spo2 100 ok", ValidSpO2Window(100), true},
		{"spo2 100.1 rejected", ValidSpO2Window(100.1), false},
		{"steps -1 rejected", ValidSteps(-1), false},
		{"steps 0 ok", ValidSteps(0), true},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s: got %v want %v", c.name, c.got, c.want)
		}
	}
}

func TestNightSummaryPercentages(t *testing.T) {
	// 28800000 ms = 8h; light = 16704000 ms (58%); sleepingTime = 28800000
	// (no wake) → Dart produces 57.99999999999999 for pctLight.
	n := NightSummary{
		DurationMs: 28800000,
		RemMs:      6336000, // 22%
		NapMs:      0,
		LightMs:    16704000, // 58%
		DeepMs:     5760000,  // 20%
	}
	if got, want := n.SleepingTimeMs(), int64(28800000); got != want {
		t.Fatalf("SleepingTimeMs: got %d want %d", got, want)
	}
	if got := n.PctLight(); got >= 58.0 {
		t.Errorf("pctLight must reproduce the float artifact (< 58.0), got %v", got)
	}
	if got, want := n.PctRem(), 22.0; got != want {
		t.Errorf("pctRem: got %v want %v", got, want)
	}
	if got, want := n.PctDeep(), 20.0; got != want {
		t.Errorf("pctDeep: got %v want %v", got, want)
	}
	n2 := NightSummary{DurationMs: 1000, WakeMs: 1000}
	if got, want := n2.PctAwake(), 100.0; got != want {
		t.Errorf("pctAwake: got %v want %v", got, want)
	}
	if got := (NightSummary{}).PctAwake(); got != 0 {
		t.Errorf("pctAwake of empty: got %v want 0", got)
	}
}

func TestBraceletRawToCanonical(t *testing.T) {
	// The EXECUTING ingestion mapping (SleepStageMapper.braceletRawToCanonical).
	// ⚠️ Conflict with the ingestion comment (1=deep/2=light) — see
	// docs/sleep-stage-mapping-investigation.md. The mapper wins (oracle).
	cases := []struct {
		raw  int
		want Stage
	}{
		{0, StageWake}, {1, StageLight}, {2, StageDeep}, {3, StageREM},
		{4, StageWake}, {-1, StageWake}, {99, StageWake},
	}
	for _, c := range cases {
		if got := BraceletRawToCanonical(c.raw); got != c.want {
			t.Errorf("BraceletRawToCanonical(%d)=%v want %v", c.raw, got, c.want)
		}
	}
	// proof of the Light/Deep canonical boundary (the conflicting claim)
	if BraceletRawToCanonical(1) != StageLight {
		t.Error("raw 1 must map to Light per the executing mapper")
	}
	if BraceletRawToCanonical(2) != StageDeep {
		t.Error("raw 2 must map to Deep per the executing mapper")
	}
}

func TestNightWindow(t *testing.T) {
	loc := time.FixedZone("BRT", -3*3600)
	start, end := NightWindow(time.Date(2026, 8, 10, 15, 0, 0, 0, loc), loc)
	wantStart := time.Date(2026, 8, 9, 18, 0, 0, 0, loc).UnixMilli()
	wantEnd := time.Date(2026, 8, 10, 12, 0, 0, 0, loc).UnixMilli()
	if start != wantStart || end != wantEnd {
		t.Errorf("NightWindow: got [%d,%d] want [%d,%d]", start, end, wantStart, wantEnd)
	}
}

func TestClampSegments(t *testing.T) {
	nightEnd := int64(1000)
	in := []Segment{
		{StartMs: 100, EndMs: 500, Stage: StageREM},
		{StartMs: 600, EndMs: 2000, Stage: StageLight}, // clamped to 1000
		{StartMs: 900, EndMs: 900, Stage: StageDeep},   // dropped (empty)
	}
	got := ClampSegments(in, nightEnd)
	if len(got) != 2 {
		t.Fatalf("len: got %d want 2", len(got))
	}
	if got[1].EndMs != 1000 {
		t.Errorf("clamped end: got %d want 1000", got[1].EndMs)
	}
}
