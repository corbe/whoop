// Readiness score — port of ReadinessScoreAlgorithm (F-03).
//
// Source: lib/core/scores/readiness_score.dart @ 5b1698f.
//
// Blend: weighted average of optional components (sleep 0.35, recovery 0.25,
// rhr 0.15?, spo2 0.10?, fatigue 0.15?) — missing components are excluded and
// weights renormalize. Then caps by TODAY's sleep score
// (<=30→35, <=40→45, <=50→58, <=60→72; else no cap). Caps only lower.
//
// Service-level gates (readiness_score.dart:192-196) are enforced by the
// engine, not here: stressScore <= 0 or todaySleepScore <= 0 → 0.
package readiness

import (
	"math"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/stats"
)

// Algorithm mirrors ReadinessScoreAlgorithm (pure).
type Algorithm struct {
	Cfg config.Readiness
}

// New returns an Algorithm with the given config (default if zero).
func New(cfg config.Readiness) *Algorithm { return &Algorithm{Cfg: cfg} }

// SleepAggregateScore mirrors sleepAggregateScore:
// round(today*wToday + hist*wHistory).clamp(0,100).
func (a *Algorithm) SleepAggregateScore(todaySleepScore, historicalAvg int) int {
	v := float64(todaySleepScore)*a.Cfg.SleepTodayWeight +
		float64(historicalAvg)*a.Cfg.SleepHistoryWeight
	return stats.ClampInt(stats.RoundInt(v), 0, 100)
}

// ScoreFatigueFromAverage mirrors scoreFatigueFromAverage: identity above
// fatigueIdentityThreshold, else piecewise lerp on knots
// [0,20]→[0,8], [20,30]→[8,15], [30,40]→[15,25], [40,50]→[25,38], [50,65]→[38,65].
func (a *Algorithm) ScoreFatigueFromAverage(averageSleepScore int) int {
	avg := stats.ClampInt(averageSleepScore, 0, 100)
	if avg >= a.Cfg.FatigueIdentityThreshold {
		return avg
	}
	switch {
	case avg >= 50:
		return stats.LerpInt(50, 38, 65, 65, avg)
	case avg >= 40:
		return stats.LerpInt(40, 25, 50, 38, avg)
	case avg >= 30:
		return stats.LerpInt(30, 15, 40, 25, avg)
	case avg >= 20:
		return stats.LerpInt(20, 8, 30, 15, avg)
	default:
		return stats.ClampInt(stats.LerpInt(0, 0, 20, 8, avg), 0, 100)
	}
}

// ApplyReadinessCaps mirrors applyReadinessCaps: min(blend, cap) by today's
// sleep score bucket; no cap above 60.
func (a *Algorithm) ApplyReadinessCaps(blendedScore, todaySleepScore int) int {
	score := stats.ClampInt(blendedScore, 0, 100)
	var cap int
	switch {
	case todaySleepScore <= 30:
		cap = a.Cfg.CapSleep30
	case todaySleepScore <= 40:
		cap = a.Cfg.CapSleep40
	case todaySleepScore <= 50:
		cap = a.Cfg.CapSleep50
	case todaySleepScore <= 60:
		cap = a.Cfg.CapSleep60
	default:
		return score
	}
	if score > cap {
		return cap
	}
	return score
}

// ScoreRhrVsBaseline mirrors scoreRhrVsBaseline:
// ratio <= 1 → 100; ratio >= rhrZeroRatio → 0; else linear.
// baseline <= 0 → 0 (the service only calls it when both are non-null).
func (a *Algorithm) ScoreRhrVsBaseline(lastNightRhr, baselineRhr float64) int {
	if baselineRhr <= 0 {
		return 0
	}
	ratio := lastNightRhr / baselineRhr
	if ratio <= 1.0 {
		return 100
	}
	if ratio >= a.Cfg.RhrZeroRatio {
		return 0
	}
	span := a.Cfg.RhrZeroRatio - 1.0
	v := ((a.Cfg.RhrZeroRatio - ratio) / span) * 100
	return stats.ClampInt(stats.RoundInt(v), 0, 100)
}

// ScoreSpo2 mirrors scoreSpo2: personal-baseline delta bands when baseline
// > 0, absolute bands otherwise (readiness_score.dart:106-123).
func (a *Algorithm) ScoreSpo2(avgPct float64, personalBaseline *float64) int {
	if personalBaseline != nil && *personalBaseline > 0 {
		delta := avgPct - *personalBaseline
		switch {
		case delta >= 0:
			return 100
		case delta >= -1:
			return stats.ClampInt(stats.RoundInt(80+delta*20), 0, 100)
		case delta >= -3:
			return stats.ClampInt(stats.RoundInt(40+(delta+3)*20), 0, 100)
		case delta >= -6:
			return stats.ClampInt(stats.RoundInt((delta+6)/3*40), 0, 100)
		default:
			return 0
		}
	}
	switch {
	case avgPct >= 96:
		return 100
	case avgPct >= 94:
		return stats.ClampInt(stats.RoundInt(20+(avgPct-94)/2*80), 0, 100)
	case avgPct >= 90:
		return stats.ClampInt(stats.RoundInt((avgPct-90)/4*20), 0, 100)
	default:
		return 0
	}
}

// Component is one readiness component for the weighted blend.
type Component struct {
	Key    string
	Score  int
	Weight float64
}

// WeightedBlend mirrors weightedBlend: round(Σ s*w / Σ w).clamp(0,100);
// 0 when total weight <= 0.
func (a *Algorithm) WeightedBlend(components []Component) int {
	ws := make([]stats.WeightedComponent, len(components))
	for i, c := range components {
		ws[i] = stats.WeightedComponent{Score: c.Score, Weight: c.Weight}
	}
	return stats.WeightedBlend(ws)
}

// Breakdown mirrors ReadinessBreakdownResult (service-level fields that the
// pure layer can compute; the engine fills RHR/SpO2/fatigue from baselines).
type Breakdown struct {
	SleepComponent     int
	RecoveryComponent  int
	RhrComponent       *int
	Spo2Component      *int
	FatigueComponent   *int
	FatigueAvgSleep    *int
	Blended            int
	TotalScore         int
	SleepHistoricalAvg int

	// Explanation data (additive; the score math is unchanged).
	Components []Component // every component used in the blend (present only)
	// CapApplied is the cap value enforced by ApplyReadinessCaps, or nil when
	// the blend passed uncapped.
	CapApplied *int
}

// Compute runs the full pure readiness pipeline.
//
// todaySleepScore and stressScore are REQUIRED (service gates: <= 0 → no
// data). sleepHistory = sleep scores for D-1..D-4 (0 = no data, skipped).
// fatigueHistory = sleep scores for D-1..D-3 (subset of sleepHistory).
// lastNightRhr/rhrBaseline, spo2Tonight/spo2Baseline optional.
func (a *Algorithm) Compute(
	todaySleepScore, stressScore int,
	sleepHistory []int,
	lastNightRhr, rhrBaseline *float64,
	spo2Tonight *float64, spo2Baseline *float64,
	fatigueHistory []int,
) *Breakdown {
	if todaySleepScore <= 0 {
		return nil
	}

	// sleepHistoricalAvg: ceil of mean of positive history; fallback today.
	histSum, histCount := 0, 0
	for _, s := range sleepHistory {
		if s > 0 {
			histSum += s
			histCount++
		}
	}
	sleepHistoricalAvg := todaySleepScore
	if histCount > 0 {
		sleepHistoricalAvg = int(math.Ceil(float64(histSum) / float64(histCount)))
	}
	sleepComponent := a.SleepAggregateScore(todaySleepScore, sleepHistoricalAvg)
	recoveryComponent := stats.ClampInt(100-stressScore, 0, 100)

	components := []Component{
		{Key: "sleep", Score: sleepComponent, Weight: a.Cfg.WeightSleep},
		{Key: "recovery", Score: recoveryComponent, Weight: a.Cfg.WeightRecovery},
	}

	var rhrComponent, spo2Component, fatigueComponent, fatigueAvg *int
	if lastNightRhr != nil && rhrBaseline != nil {
		v := a.ScoreRhrVsBaseline(*lastNightRhr, *rhrBaseline)
		rhrComponent = &v
		components = append(components, Component{Key: "rhr", Score: v, Weight: a.Cfg.WeightRhr})
	}
	if spo2Tonight != nil {
		v := a.ScoreSpo2(*spo2Tonight, spo2Baseline)
		spo2Component = &v
		components = append(components, Component{Key: "spo2", Score: v, Weight: a.Cfg.WeightSpo2})
	}
	{
		fSum, fCount := 0, 0
		for _, s := range fatigueHistory {
			if s > 0 {
				fSum += s
				fCount++
			}
		}
		if fCount > 0 {
			avg := stats.RoundInt(float64(fSum) / float64(fCount))
			fatigueAvg = &avg
			v := a.ScoreFatigueFromAverage(avg)
			fatigueComponent = &v
			components = append(components, Component{Key: "fatigue", Score: v, Weight: a.Cfg.WeightFatigue})
		}
	}

	blended := a.WeightedBlend(components)
	total := a.ApplyReadinessCaps(blended, todaySleepScore)
	var capApplied *int
	if total != blended {
		c := total
		capApplied = &c
	}

	return &Breakdown{
		SleepComponent:     sleepComponent,
		RecoveryComponent:  recoveryComponent,
		RhrComponent:       rhrComponent,
		Spo2Component:      spo2Component,
		FatigueComponent:   fatigueComponent,
		FatigueAvgSleep:    fatigueAvg,
		Blended:            blended,
		TotalScore:         total,
		SleepHistoricalAvg: sleepHistoricalAvg,
		Components:         components,
		CapApplied:         capApplied,
	}
}
