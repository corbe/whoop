// Sleep score — port of SleepScoreAlgorithm.compute (F-01).
//
// Source: lib/core/scores/sleep_score.dart @ 5b1698f. Discount model:
// score = clamp(100 - (qualityDiscount + bedTimeDiscount + targetSleepDiscount),
// 0, 100). The total discount is INT-TRUNCATED (Dart .toInt()), not rounded.
//
// DEAD-PATH PRESERVED for parity: the early-sleep coefficients
// (EarlyCoefLight/EarlyCoefHeavy) only ever multiply a bedTimeDiscount of 0
// (the early branches never set the late discount), so going to bed early
// NEVER changes the score — exactly as in ritma-app (audit F-01 NOTE).
package sleep

import (
	"math"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/stats"
)

// Result mirrors the map returned by SleepScoreAlgorithm.compute.
type Result struct {
	Score         int
	BateriaZerada bool
	PctRem        float64
	PctDeep       float64
	PctLight      float64
	StartMs       int64
	EndMs         int64
	SleepingMs    int64
	Msg1          int
	Msg2          int
	Msg3          int

	// Explanation intermediates (exact values used in the discount model;
	// additive — the score math above is unchanged).
	BedTimeDiscount     float64 // raw before truncation
	TargetSleepDiscount float64 // raw before truncation
	QualityDiscount     float64 // integer-valued sum of stage discounts
	TotalDiscount       float64 // pre-truncation sum
}

// Compute runs the pure sleep-score algorithm.
//
// summary may be empty (IsEmpty) → {Score: 0, BateriaZerada: false};
// batteryDepleted → {Score: 0, BateriaZerada: true}.
func Compute(summary domain.NightSummary, bedTimeMinutes, sleepTargetMinutes int, cfg config.Sleep) Result {
	if summary.IsEmpty() {
		return Result{}
	}
	if summary.BatteryDepleted {
		return Result{BateriaZerada: true}
	}

	onTime := cfg.OnTimeThresholdMin
	somewhat := cfg.SomewhatThresholdMin

	// minuteOfDay of the sleep start (local wall clock).
	dt := timeFromMs(summary.StartMs)
	minutoReal := dt.Hour()*60 + dt.Minute()

	diferenca := minutoReal - bedTimeMinutes
	if diferenca > 720 {
		diferenca -= 1440
	} else if diferenca < -720 {
		diferenca += 1440
	}

	// coef0 for the bedtime discount — dead path preserved (see header).
	coef0 := 1.0
	switch {
	case math.Abs(float64(diferenca)) <= float64(onTime):
		// na hora
	case diferenca > onTime && diferenca <= somewhat:
		// um pouco tarde
	case diferenca > somewhat:
		// muito tarde
	case diferenca < -onTime && diferenca >= -somewhat:
		coef0 = cfg.EarlyCoefLight
	default:
		coef0 = cfg.EarlyCoefHeavy
	}

	bedTimeDiscount := 0.0
	if diferenca > onTime && diferenca <= somewhat {
		bedTimeDiscount = float64(diferenca-onTime) * cfg.BedLateCoef1
	} else if diferenca > somewhat {
		bedTimeDiscount = float64(somewhat-onTime)*cfg.BedLateCoef1 +
			float64(diferenca-somewhat)*cfg.BedLateCoef2
	}
	bedTimeDiscount = math.Min(bedTimeDiscount*coef0, cfg.MaxBedTimeDiscount)

	sleepingMin := stats.RoundInt(float64(summary.SleepingTimeMs()) / 60000)
	diferenca2 := sleepingMin - sleepTargetMinutes

	coef0 = 1.0
	if diferenca2 > onTime && diferenca2 <= somewhat {
		coef0 = cfg.DurationOverCoefLight
	} else if diferenca2 > somewhat {
		coef0 = cfg.DurationOverCoefHeavy
	}

	abs2 := int(math.Abs(float64(diferenca2)))
	targetSleepDiscount := 0.0
	switch {
	case abs2 > onTime && abs2 <= somewhat:
		targetSleepDiscount = float64(abs2-onTime) * cfg.DurationCoef1
	case abs2 > somewhat && abs2 <= 180:
		targetSleepDiscount = float64(somewhat-onTime)*cfg.DurationCoef1 +
			float64(abs2-somewhat)*cfg.DurationCoef2
	case abs2 > 180:
		targetSleepDiscount = float64(somewhat-onTime)*cfg.DurationCoef1 +
			float64(180-somewhat)*cfg.DurationCoef2 +
			float64(abs2-180)*cfg.DurationCoef3
	}
	targetSleepDiscount = math.Min(targetSleepDiscount*coef0, cfg.MaxDurationDiscount)

	qualityDiscount := float64(stageQualityDiscount(summary.PctRem()) +
		stageQualityDiscount(summary.PctDeep()))

	totalDiscount := stats.TruncInt(qualityDiscount + bedTimeDiscount + targetSleepDiscount)
	score := stats.ClampInt(100-totalDiscount, 0, 100)

	return Result{
		Score:               score,
		BateriaZerada:       false,
		PctRem:              summary.PctRem(),
		PctDeep:             summary.PctDeep(),
		PctLight:            summary.PctLight(),
		StartMs:             summary.StartMs,
		EndMs:               summary.EndMs,
		SleepingMs:          summary.SleepingTimeMs(),
		Msg1:                msg1(diferenca, onTime, somewhat),
		Msg2:                msg2(diferenca2, onTime, somewhat),
		Msg3:                msg3(summary),
		BedTimeDiscount:     bedTimeDiscount,
		TargetSleepDiscount: targetSleepDiscount,
		QualityDiscount:     qualityDiscount,
		TotalDiscount:       qualityDiscount + bedTimeDiscount + targetSleepDiscount,
	}
}

// stageQualityDiscount mirrors _stageQualityDiscount (sleep_score.dart:151-157).
func stageQualityDiscount(pct float64) int {
	switch {
	case pct < 10:
		return 5
	case pct < 15:
		return 4
	case pct < 20:
		return 3
	case pct > 27.5:
		return 2
	}
	return 0
}

// msg1 mirrors the bedtime analysis code (sleep_score.dart:96-107).
func msg1(diferenca, onTime, somewhat int) int {
	switch {
	case math.Abs(float64(diferenca)) <= float64(onTime):
		return 0
	case diferenca > onTime && diferenca <= somewhat:
		return 1
	case diferenca > somewhat:
		return 2
	case diferenca < -onTime && diferenca >= -somewhat:
		return 3
	}
	return 4
}

// msg2 mirrors the duration analysis code (sleep_score.dart:109-118).
func msg2(diferenca2, onTime, somewhat int) int {
	abs2 := int(math.Abs(float64(diferenca2)))
	switch {
	case abs2 <= onTime:
		return 0
	case diferenca2 > onTime && diferenca2 <= somewhat:
		return 1
	case diferenca2 < -onTime && diferenca2 >= -somewhat:
		return 2
	case abs2 > somewhat:
		if diferenca2 > 0 {
			return 3
		}
		return 4
	}
	return 0
}

// msg3 mirrors the stage-quality code (sleep_score.dart:120-134).
func msg3(summary domain.NightSummary) int {
	pctLight := summary.PctLight()
	pctDeep := summary.PctDeep()
	pctRem := summary.PctRem()
	switch {
	case pctDeep < 15 && pctRem >= 20:
		return 1
	case pctRem < 20 && pctDeep >= 15:
		return 2
	case pctLight > 50 && pctDeep >= 15 && pctRem >= 20:
		return 3
	case pctDeep > 25 && pctRem > 27.5:
		return 4
	case pctRem > 27.5:
		return 5
	}
	return 0
}

func timeFromMs(ms int64) time.Time { return time.UnixMilli(ms) }
