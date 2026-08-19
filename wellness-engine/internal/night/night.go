// Night pipeline — port of SleepStageSummary.forNight (F-12).
//
// Source: lib/core/utils/sleep_stage_summary.dart @ 5b1698f.
// This is the highest-risk logic in the port; behavior is verified against
// golden cases N1-N5 (docs/wellness-golden-dataset.md) and, where the hand
// derivation was wrong (case N3: a segment clamped at nightEnd produces a
// DEGENERATE window [start,start] with full stage durations — NOT an empty
// night), the EXECUTING Dart behavior wins.
package night

import (
	"sort"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/stats"
)

const (
	// longAwakeThresholdMs mirrors _longAwakeThresholdMs (1h).
	longAwakeThresholdMs int64 = 60 * 60 * 1000
	// maxNightDurationMs mirrors _maxNightDurationMs (16h).
	maxNightDurationMs int64 = 16 * 60 * 60 * 1000
)

// BatterySample is a (timestamp, value) battery reading (BatteryRecord).
type BatterySample struct {
	TimestampMs int64
	Value       float64
}

// Input bundles everything forNight consumes from Isar in the Dart code.
type Input struct {
	Segments   []domain.Segment // raw in-window segments (canonical stages)
	HRVMs      []float64        // HRV samples (ms), unfiltered
	Battery    []BatterySample  // all battery samples; last before end+1 wins
	Location   *time.Location
	AnchorDate time.Time
}

// ForNight mirrors SleepStageSummary.forNight.
func ForNight(in Input) domain.NightSummary {
	if in.Location == nil {
		in.Location = time.Local
	}
	// nightStart is used for documentation parity with the Dart window
	// (records are selected with startTs in (nightStart-1, nightEnd)); the
	// caller is responsible for the in-window selection, matching the Dart
	// query filter (sleep_stage_summary.dart:222-230).
	_, nightEnd := domain.NightWindow(in.AnchorDate, in.Location)

	segs := domain.ClampSegments(in.Segments, nightEnd)
	if len(segs) == 0 {
		return empty()
	}
	sort.Slice(segs, func(i, j int) bool { return segs[i].StartMs < segs[j].StartMs })

	processed := processSegmentsForValidNight(segs, nightEnd)
	if processed == nil {
		return empty()
	}

	var wake, rem, nap, light, deep int64
	for _, seg := range processed.segments {
		dur := seg.EndMs - seg.StartMs
		if dur <= 0 {
			continue
		}
		switch seg.Stage {
		case domain.StageWake:
			wake += dur
		case domain.StageREM:
			rem += dur
		case domain.StageNap:
			nap += dur
		case domain.StageLight:
			light += dur
		case domain.StageDeep:
			deep += dur
		}
	}

	totalDuration := int64(0)
	for _, seg := range processed.segments {
		d := seg.EndMs - seg.StartMs
		if d > 0 {
			totalDuration += d
		}
	}
	if totalDuration <= 0 {
		return empty()
	}
	durationCapped := false
	if totalDuration > maxNightDurationMs {
		totalDuration = maxNightDurationMs
		durationCapped = true
	}

	// avgHrvMs: mean of HRV > 0 in [windowStart, windowEnd] (inclusive).
	var avgHrv *float64
	var hrvVals []float64
	for _, v := range in.HRVMs {
		if v > 0 {
			hrvVals = append(hrvVals, v)
		}
	}
	if len(hrvVals) > 0 {
		m := stats.Mean(hrvVals)
		avgHrv = &m
	}

	// batteryDepleted: last battery sample with timestamp < maxEnd+1, value < 3.0.
	depleted := false
	lastTs := int64(-1)
	var lastVal float64
	for _, b := range in.Battery {
		if b.TimestampMs < processed.windowEnd+1 && b.TimestampMs > lastTs {
			lastTs = b.TimestampMs
			lastVal = b.Value
		}
	}
	if lastTs >= 0 && lastVal < 3.0 {
		depleted = true
	}

	return domain.NightSummary{
		StartMs:          processed.windowStart,
		EndMs:            processed.windowEnd,
		DurationMs:       totalDuration,
		WakeMs:           wake,
		RemMs:            rem,
		NapMs:            nap,
		LightMs:          light,
		DeepMs:           deep,
		AvgHrvMs:         avgHrv,
		BatteryDepleted:  depleted,
		DurationCapped:   durationCapped,
		DegenerateWindow: processed.windowEnd == processed.windowStart,
	}
}

func empty() domain.NightSummary { return domain.NightSummary{} }

type processedNight struct {
	segments    []domain.Segment
	windowStart int64
	windowEnd   int64
}

// processSegmentsForValidNight mirrors _processSegmentsForValidNight:
// gap-fill → expunge around first >=1h awake run → re-bounds → gap-fill.
func processSegmentsForValidNight(segs []domain.Segment, nightEnd int64) *processedNight {
	if len(segs) == 0 {
		return nil
	}

	start, end := windowBoundsFromSegments(segs, nightEnd)
	filled := fillGapsAsAwake(segs, start, end)

	kept := discardBeforeLongAwakeGap(filled)
	if len(kept) == 0 {
		return nil
	}

	start, end = windowBoundsFromSegments(kept, nightEnd)
	filled = fillGapsAsAwake(kept, start, end)
	if len(filled) == 0 {
		return nil
	}

	return &processedNight{segments: filled, windowStart: start, windowEnd: end}
}

// windowBoundsFromSegments mirrors _windowBoundsFromSegments. NOTE the
// degenerate-window behavior: when the segment that sets maxEnd is clamped at
// nightEnd, maxEnd is replaced by the LAST segment's start (which can make
// windowEnd == windowStart — a zero-width window, NOT an empty night).
func windowBoundsFromSegments(segs []domain.Segment, nightEnd int64) (int64, int64) {
	minStart := segs[0].StartMs
	maxEnd := int64(0)
	lastEndWasClamped := false

	for _, seg := range segs {
		if seg.StartMs < minStart {
			minStart = seg.StartMs
		}
		if seg.EndMs > maxEnd {
			maxEnd = seg.EndMs
			lastEndWasClamped = seg.EndMs == nightEnd
		}
	}
	if lastEndWasClamped && len(segs) > 0 {
		maxEnd = segs[len(segs)-1].StartMs
	}
	return minStart, maxEnd
}

// fillGapsAsAwake mirrors _fillGapsAsAwake: fills [windowStart, windowEnd)
// with Wake(0) wherever segments are missing, merging overlaps by cursor
// advance. Returns the input unchanged when the window is degenerate.
func fillGapsAsAwake(segs []domain.Segment, windowStart, windowEnd int64) []domain.Segment {
	if len(segs) == 0 || windowEnd <= windowStart {
		return segs
	}

	sorted := append([]domain.Segment(nil), segs...)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].StartMs != sorted[j].StartMs {
			return sorted[i].StartMs < sorted[j].StartMs
		}
		return sorted[i].EndMs > sorted[j].EndMs
	})

	filled := make([]domain.Segment, 0, len(sorted)*2)
	cursor := windowStart
	for _, seg := range sorted {
		if seg.EndMs <= cursor {
			continue
		}
		segStart := seg.StartMs
		if segStart < cursor {
			segStart = cursor
		}
		segEnd := seg.EndMs
		if segEnd > windowEnd {
			segEnd = windowEnd
		}
		if segStart >= segEnd {
			continue
		}
		if cursor < segStart {
			filled = append(filled, domain.Segment{StartMs: cursor, EndMs: segStart, Stage: domain.StageWake})
		}
		filled = append(filled, domain.Segment{StartMs: segStart, EndMs: segEnd, Stage: seg.Stage})
		if segEnd > cursor {
			cursor = segEnd
		}
	}
	if cursor < windowEnd {
		filled = append(filled, domain.Segment{StartMs: cursor, EndMs: windowEnd, Stage: domain.StageWake})
	}
	return filled
}

// discardBeforeLongAwakeGap mirrors _discardBeforeLongAwakeGap: finds the
// FIRST continuous wake run (>=1h, gaps included) and keeps the side with
// more non-wake sleep (ties keep AFTER).
func discardBeforeLongAwakeGap(segs []domain.Segment) []domain.Segment {
	var awakeRunStart, awakeRunEnd int64
	found := false
	for _, seg := range segs {
		if seg.Stage == domain.StageWake {
			if awakeRunEnd == 0 || seg.StartMs > awakeRunEnd {
				awakeRunStart = seg.StartMs
				awakeRunEnd = seg.EndMs
			} else if seg.EndMs > awakeRunEnd {
				awakeRunEnd = seg.EndMs
			}
			if awakeRunEnd-awakeRunStart >= longAwakeThresholdMs {
				found = true
				break
			}
		} else {
			awakeRunStart = 0
			awakeRunEnd = 0
		}
	}
	if !found {
		return segs
	}

	sleepDuration := func(xs []domain.Segment) int64 {
		var sum int64
		for _, s := range xs {
			if s.Stage != domain.StageWake {
				sum += s.EndMs - s.StartMs
			}
		}
		return sum
	}

	var before, after []domain.Segment
	for _, s := range segs {
		if s.EndMs <= awakeRunStart {
			before = append(before, s)
		} else if s.StartMs >= awakeRunEnd {
			after = append(after, s)
		}
	}
	if sleepDuration(after) >= sleepDuration(before) {
		return after
	}
	return before
}
