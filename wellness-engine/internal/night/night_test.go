package night

import (
	"testing"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
)

// Golden cases N1-N5 from docs/wellness-golden-dataset.md. All times local
// (America/Sao_Paulo), night D = 2026-08-10 → window [2026-08-09 18:00,
// 2026-08-10 12:00].
//
// CORRECTION vs the hand-derived doc: case N3 (single segment clamped at
// nightEnd) does NOT produce an empty night — the executing Dart code yields
// a DEGENERATE window [start,start] with full stage durations counted.
// The Go port reproduces the executing behavior; the doc was amended.

var br = time.FixedZone("BRT", -3*3600)

func ms(y int, mo time.Month, d, h, mi int) int64 {
	return time.Date(y, mo, d, h, mi, 0, 0, br).UnixMilli()
}

func anchor() time.Time { return time.Date(2026, 8, 10, 15, 0, 0, 0, br) }

const hourMs = int64(3600000)

func TestNightN1NormalWithGap(t *testing.T) {
	// [22:00→23:00 REM], [23:00→00:30 Light], 30-min missing,
	// [01:00→06:30 Light], [06:30→07:00 REM]
	in := Input{
		Segments: []domain.Segment{
			{StartMs: ms(2026, 8, 9, 22, 0), EndMs: ms(2026, 8, 9, 23, 0), Stage: domain.StageREM},
			{StartMs: ms(2026, 8, 9, 23, 0), EndMs: ms(2026, 8, 10, 0, 30), Stage: domain.StageLight},
			{StartMs: ms(2026, 8, 10, 1, 0), EndMs: ms(2026, 8, 10, 6, 30), Stage: domain.StageLight},
			{StartMs: ms(2026, 8, 10, 6, 30), EndMs: ms(2026, 8, 10, 7, 0), Stage: domain.StageREM},
		},
		Location:   br,
		AnchorDate: anchor(),
	}
	s := ForNight(in)
	if s.IsEmpty() {
		t.Fatal("expected non-empty night")
	}
	if s.StartMs != ms(2026, 8, 9, 22, 0) || s.EndMs != ms(2026, 8, 10, 7, 0) {
		t.Errorf("window: got [%d,%d] want [22:00,07:00]", s.StartMs, s.EndMs)
	}
	if want := int64(9 * hourMs); s.DurationMs != want {
		t.Errorf("duration: got %d want %d", s.DurationMs, want)
	}
	if want := int64(30 * 60000); s.WakeMs != want {
		t.Errorf("wake: got %d want %d (30min gap)", s.WakeMs, want)
	}
	if want := int64(3 * hourMs / 2); s.RemMs != want {
		t.Errorf("rem: got %d want %d (1h+0.5h)", s.RemMs, want)
	}
	if want := int64(7 * hourMs); s.LightMs != want {
		t.Errorf("light: got %d want %d", s.LightMs, want)
	}
	if want := int64(30600000); s.SleepingTimeMs() != want {
		t.Errorf("sleepingTime: got %d want 30600000", s.SleepingTimeMs())
	}
	if s.PctRem() < 17.64 || s.PctRem() > 17.66 {
		t.Errorf("pctRem: got %v want ~17.65", s.PctRem())
	}
}

func TestNightN2SplitByLongAwakeGap(t *testing.T) {
	// [22:00→01:00 Light], [01:00→02:30 Wake], [02:30→06:00 Light]
	in := Input{
		Segments: []domain.Segment{
			{StartMs: ms(2026, 8, 9, 22, 0), EndMs: ms(2026, 8, 10, 1, 0), Stage: domain.StageLight},
			{StartMs: ms(2026, 8, 10, 1, 0), EndMs: ms(2026, 8, 10, 2, 30), Stage: domain.StageWake},
			{StartMs: ms(2026, 8, 10, 2, 30), EndMs: ms(2026, 8, 10, 6, 0), Stage: domain.StageLight},
		},
		Location:   br,
		AnchorDate: anchor(),
	}
	s := ForNight(in)
	if s.IsEmpty() {
		t.Fatal("expected non-empty night (keeps the heavier side)")
	}
	// after (3.5h light) >= before (3h light) → keep AFTER
	if s.StartMs != ms(2026, 8, 10, 2, 30) || s.EndMs != ms(2026, 8, 10, 6, 0) {
		t.Errorf("window: got [%d,%d] want [02:30,06:00]", s.StartMs, s.EndMs)
	}
	if want := int64(12600000); s.SleepingTimeMs() != want {
		t.Errorf("sleepingTime: got %d want 12600000", s.SleepingTimeMs())
	}
	if s.WakeMs != 0 {
		t.Errorf("wake must be 0 after expunge, got %d", s.WakeMs)
	}
	if s.LightMs != int64(12600000) {
		t.Errorf("light: got %d want 12600000", s.LightMs)
	}
}

func TestNightN3ClampedAtNightEnd(t *testing.T) {
	// Single Deep segment [22:00 → 12:00] ending exactly at nightEnd.
	// EXECUTING behavior: degenerate window [22:00, 22:00], duration NOT
	// empty — full 14h of deep sleep counted.
	in := Input{
		Segments: []domain.Segment{
			{StartMs: ms(2026, 8, 9, 22, 0), EndMs: ms(2026, 8, 10, 12, 0), Stage: domain.StageDeep},
		},
		Location:   br,
		AnchorDate: anchor(),
	}
	s := ForNight(in)
	if s.IsEmpty() {
		t.Fatal("N3: clamped-at-nightEnd segment must NOT produce an empty night (executing Dart behavior)")
	}
	if s.StartMs != ms(2026, 8, 9, 22, 0) || s.EndMs != ms(2026, 8, 9, 22, 0) {
		t.Errorf("window: got [%d,%d] want degenerate [22:00,22:00]", s.StartMs, s.EndMs)
	}
	if !s.DegenerateWindow {
		t.Error("DegenerateWindow must be true")
	}
	if want := int64(14 * hourMs); s.DeepMs != want {
		t.Errorf("deep: got %d want %d", s.DeepMs, want)
	}
	if s.DurationMs != int64(14*hourMs) {
		t.Errorf("duration: got %d want 14h", s.DurationMs)
	}
}

func TestNightN4DurationCap(t *testing.T) {
	// Segments spanning the full night window [18:00 → 12:00] (18h) → the
	// per-stage sums are 18h but totalDuration caps at 16h.
	in := Input{
		Segments: []domain.Segment{
			{StartMs: ms(2026, 8, 9, 18, 0), EndMs: ms(2026, 8, 10, 12, 0), Stage: domain.StageLight},
		},
		Location:   br,
		AnchorDate: anchor(),
	}
	s := ForNight(in)
	if s.IsEmpty() {
		t.Fatal("expected non-empty night")
	}
	if s.DurationMs != maxNightDurationMs {
		t.Errorf("duration: got %d want %d (16h cap)", s.DurationMs, maxNightDurationMs)
	}
	if !s.DurationCapped {
		t.Error("DurationCapped must be true")
	}
	// per-stage sums are NOT capped (18h light), matching Dart.
	if want := int64(18 * hourMs); s.LightMs != want {
		t.Errorf("light: got %d want %d (uncapped 18h)", s.LightMs, want)
	}
}

func TestNightN5BatteryAndHRV(t *testing.T) {
	in := Input{
		Segments: []domain.Segment{
			{StartMs: ms(2026, 8, 9, 22, 0), EndMs: ms(2026, 8, 10, 7, 0), Stage: domain.StageLight},
		},
		HRVMs: []float64{40, 45, 50},
		Battery: []BatterySample{
			{TimestampMs: ms(2026, 8, 9, 21, 0), Value: 90},
			{TimestampMs: ms(2026, 8, 10, 6, 59), Value: 2.5}, // < 3.0 before end+1
		},
		Location:   br,
		AnchorDate: anchor(),
	}
	s := ForNight(in)
	if !s.BatteryDepleted {
		t.Error("batteryDepleted must be true (2.5 < 3.0)")
	}
	if s.AvgHrvMs == nil || *s.AvgHrvMs != 45.0 {
		t.Errorf("avgHrv: got %v want 45.0", s.AvgHrvMs)
	}

	// battery sample AFTER end+1 must not count
	in2 := Input{
		Segments: in.Segments,
		Battery: []BatterySample{
			{TimestampMs: ms(2026, 8, 10, 7, 1), Value: 2.0}, // after window end+1
		},
		Location:   br,
		AnchorDate: anchor(),
	}
	if s2 := ForNight(in2); s2.BatteryDepleted {
		t.Error("batteryDepleted must be false for a sample after end+1")
	}
}

func TestNightEmpty(t *testing.T) {
	if s := ForNight(Input{Location: br, AnchorDate: anchor()}); !s.IsEmpty() {
		t.Error("no segments → empty summary")
	}
	if s := ForNight(Input{Segments: []domain.Segment{{StartMs: 1, EndMs: 1, Stage: domain.StageDeep}}, Location: br, AnchorDate: anchor()}); !s.IsEmpty() {
		t.Error("zero-duration segment → empty summary")
	}
}
