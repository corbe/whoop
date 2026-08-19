// Domain types for the RITMA wellness calculation engine.
//
// Ported from ritma-app (noana-org/ritma-app @ 5b1698f, branch
// feat/go-wellness-engine). The math must reproduce the Dart implementation
// EXACTLY for the same input (see docs/wellness-golden-dataset.md and
// docs/golden/oracle.json — the machine-executed compatibility oracle).
//
// Conventions (from docs/wellness-input-contract.md):
//   - timestamps are Unix epoch MILLISECONDS, local-time semantics
//   - 0 means "no data" everywhere scores are concerned (never a bad value)
//   - steps are cumulative daily counters; HR 30<x<220; SpO2 70..100;
//     sleep stages canonical: 0=Wake, -1=REM, -2=Nap, -3=Light, -4=Deep
package domain

import (
	"fmt"
	"time"
)

// Metric identifies the physiological quantity a Measurement carries.
type Metric string

const (
	MetricHeartRate   Metric = "heart_rate"  // bpm
	MetricHRV         Metric = "hrv"         // ms (device-computed; assumed RMSSD)
	MetricSpO2        Metric = "spo2_pct"    // percent
	MetricTemperature Metric = "temperature" // Celsius
	MetricSteps       Metric = "steps"       // cumulative daily count
	MetricBattery     Metric = "battery_pct" // percent
	MetricCalories    Metric = "calories"    // kcal
	MetricDistanceM   Metric = "distance_m"  // meters
)

// DeviceSource mirrors the Dart deviceSource field.
type DeviceSource string

const (
	DeviceBracelet DeviceSource = "BRACELET"
	DeviceAPI      DeviceSource = "API"
	DeviceRing     DeviceSource = "RING" // never written by ritma-app; read-side only
)

// Measurement is one raw sample. Mirrors HeartRateRecord/HrvRecord/
// OxygenRecord/TemperatureRecord/StepsRecord from health_collections.dart.
type Measurement struct {
	PersonID  string
	Metric    Metric
	Timestamp time.Time
	Value     float64
	// Steps-only ride-along fields (StepsRecord.calories / .distance).
	Calories *float64
	DistM    *float64
	Device   DeviceSource
}

// Valid-range checks — exactly the consumer-enforced filters from the audit.
// (bracelet_service.dart filters are ingestion-side; these are the SCORE-side
// filters used by baselines and scoring.)

// ValidHeartRate: 30 < bpm < 220 (wellness_baselines.dart:103).
func ValidHeartRate(bpm float64) bool { return bpm > 30 && bpm < 220 }

// ValidHRV: > 0 ms (stress_score.dart:122, sleep_stage_summary.dart:146).
func ValidHRV(ms float64) bool { return ms > 0 }

// ValidSpO2Window: 70 <= pct <= 100 — baseline window filter
// (wellness_baselines.dart:216,229). NOTE: ingestion uses `> 70` EXCLUSIVE
// (bracelet_service.dart:690); a sample of exactly 70 is rejected at
// ingestion but accepted here. Both behaviors are preserved at their sites.
func ValidSpO2Window(pct float64) bool { return pct >= 70 && pct <= 100 }

// ValidSteps: >= 0; baseline loops require > 0 to count a sample day.
func ValidSteps(n float64) bool { return n >= 0 }

// Stage is the canonical sleep stage: 0=Wake, -1=REM, -2=Nap, -3=Light, -4=Deep.
type Stage int

const (
	StageWake  Stage = 0
	StageREM   Stage = -1
	StageNap   Stage = -2
	StageLight Stage = -3
	StageDeep  Stage = -4
)

// ValidStage reports whether s is one of the five canonical stages.
func ValidStage(s Stage) bool {
	switch s {
	case StageWake, StageREM, StageNap, StageLight, StageDeep:
		return true
	}
	return false
}

// BraceletRawToCanonical ports SleepStageMapper.braceletRawToCanonical
// (lib/core/utils/sleep_stage_mapper.dart:18-31) — the EXECUTING ingestion
// mapping for JStyle bracelet raw stage values:
//
//	raw 0 → Wake, raw 1 → Light, raw 2 → Deep, raw 3 → REM, default → Wake
//
// ⚠️ MAPPING CONFLICT (see docs/sleep-stage-mapping-investigation.md): the
// ingestion comment in bracelet_service.dart:768-773 claims raw 1=deep /
// 2=light. The EXECUTING mapper (this function) is the behavioral oracle and
// is preserved. Real-device verification is BLOCKING before production
// cutover. The scoring engine consumes ONLY canonical stages — this boundary
// is the single raw→canonical translation point.
func BraceletRawToCanonical(raw int) Stage {
	switch raw {
	case 0:
		return StageWake
	case 1:
		return StageLight
	case 2:
		return StageDeep
	case 3:
		return StageREM
	default:
		return StageWake
	}
}

// Segment is a sleep-stage interval [StartMs, EndMs), half-open, matching
// SleepStageRecord (startTs/endTs/stage canonical).
type Segment struct {
	StartMs int64
	EndMs   int64
	Stage   Stage
}

// ValidSegment checks end > start and a canonical stage (the same filter as
// sleep_stage_summary.dart:232-235).
func (s Segment) Valid() bool {
	return s.EndMs > s.StartMs && ValidStage(s.Stage)
}

// NightSummary is the F-12 output (SleepStageSummary equivalent):
// the processed night in the window [18:00 D-1, 12:00 D] local time.
type NightSummary struct {
	StartMs         int64
	EndMs           int64
	DurationMs      int64 // sum of filled segments, capped at 16h
	WakeMs          int64
	RemMs           int64
	NapMs           int64
	LightMs         int64
	DeepMs          int64
	AvgHrvMs        *float64 // mean of HRV > 0 in [StartMs, EndMs]; nil if none
	BatteryDepleted bool     // last battery sample before EndMs+1 < 3.0
	// DurationCapped is true when the raw night duration exceeded the 16h cap
	// (quality flag for the explanation engine; does not affect the math).
	DurationCapped bool
	// DegenerateWindow is true when the processed window is zero-width
	// (StartMs == EndMs) — real executing behavior for nightEnd-clamped
	// segments (golden case N3). Quality flag only.
	DegenerateWindow bool
}

// IsEmpty mirrors SleepStageSummary.isEmpty: duration <= 0.
func (n NightSummary) IsEmpty() bool { return n.DurationMs <= 0 }

// SleepingTimeMs mirrors sleepingTime = rem+nap+light+deep (wake excluded).
func (n NightSummary) SleepingTimeMs() int64 {
	return n.RemMs + n.NapMs + n.LightMs + n.DeepMs
}

// PctLight/PctDeep/PctRem/PctNap: stage/sleepingTime*100 (0 when sleepingTime
// is 0). NOTE: reproduced with IEEE754 double semantics — the Dart code can
// produce 57.99999999999999 for what looks like 58.0 (golden case
// sleep_ideal). Tests compare with tolerance.
func (n NightSummary) PctLight() float64 { return pct(n.LightMs, n.SleepingTimeMs()) }
func (n NightSummary) PctDeep() float64  { return pct(n.DeepMs, n.SleepingTimeMs()) }
func (n NightSummary) PctRem() float64   { return pct(n.RemMs, n.SleepingTimeMs()) }
func (n NightSummary) PctNap() float64   { return pct(n.NapMs, n.SleepingTimeMs()) }

// PctAwake: wake/duration*100 (0 when duration is 0).
func (n NightSummary) PctAwake() float64 { return pct(n.WakeMs, n.DurationMs) }

func pct(part, totalMs int64) float64 {
	if totalMs <= 0 {
		return 0
	}
	return float64(part) / float64(totalMs) * 100
}

// DayAnchor returns the local-midnight anchor for a date (Dart DateTime(y,m,d)).
func DayAnchor(t time.Time, loc *time.Location) time.Time {
	if loc == nil {
		loc = time.Local
	}
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, loc)
}

// NightWindow returns [18:00 D-1, 12:00 D] local ms, matching
// sleep_stage_summary.dart:213-220.
func NightWindow(anchor time.Time, loc *time.Location) (startMs, endMs int64) {
	day := DayAnchor(anchor, loc)
	prev := day.AddDate(0, 0, -1)
	start := time.Date(prev.Year(), prev.Month(), prev.Day(), 18, 0, 0, 0, loc)
	end := time.Date(day.Year(), day.Month(), day.Day(), 12, 0, 0, 0, loc)
	return start.UnixMilli(), end.UnixMilli()
}

// ValidateSegmentInput is a small helper for callers that feed raw segments:
// it clamps end to nightEnd and drops empty ones (Dart
// sleep_stage_summary.dart:238-244).
func ClampSegments(segs []Segment, nightEndMs int64) []Segment {
	out := make([]Segment, 0, len(segs))
	for _, s := range segs {
		e := s.EndMs
		if e > nightEndMs {
			e = nightEndMs
		}
		if e <= s.StartMs {
			continue
		}
		out = append(out, Segment{StartMs: s.StartMs, EndMs: e, Stage: s.Stage})
	}
	return out
}

// ErrNoData is returned when a calculation cannot run for lack of data
// (the app returns 0 / empty in these cases; the engine surfaces them as
// typed errors so callers can distinguish "no data" from "invalid input").
type ErrNoData struct{ Reason string }

func (e *ErrNoData) Error() string { return "no data: " + e.Reason }

func NoData(reason string) error { return &ErrNoData{Reason: reason} }

// ErrInvalidInput is returned for structurally invalid inputs (bad ranges,
// impossible windows) — distinct from "no data" (which is a legitimate state).
type ErrInvalidInput struct{ Reason string }

func (e *ErrInvalidInput) Error() string { return "invalid input: " + e.Reason }

func InvalidInput(format string, args ...any) error {
	return &ErrInvalidInput{Reason: fmt.Sprintf(format, args...)}
}
