// Activity score — port of ActivityScoreAlgorithm + ActivityKcalGoal (F-04).
//
// Source: lib/core/scores/activity_score.dart @ 5b1698f.
//
// Steps are CUMULATIVE daily counters: aggregation takes the PEAK (max) of
// value/calories/distance across records, preferring BRACELET → RING → rest
// (device-preference order matters).
package activity

import (
	"sort"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/stats"
)

// StepsRecord mirrors StepsRecord (value/calories/distance/deviceSource).
type StepsRecord struct {
	Value     float64
	Calories  float64
	DistanceM float64
	Timestamp int64
	Device    domain.DeviceSource
}

// KcalGoal mirrors ActivityKcalGoal.
type KcalGoal struct {
	Cfg config.Activity
}

// GoalKcalFromSteps mirrors goalKcalFromSteps:
// round(goalSteps * kcalPerStep) → round to nearest 10 → clamp [150, 800].
// goalSteps <= 0 → minGoalKcal.
func (g *KcalGoal) GoalKcalFromSteps(goalSteps int) int {
	if goalSteps <= 0 {
		return g.Cfg.MinGoalKcal
	}
	raw := stats.RoundInt(float64(goalSteps) * g.Cfg.KcalPerStep)
	rounded := roundToNearest10(raw)
	return stats.ClampInt(rounded, g.Cfg.MinGoalKcal, g.Cfg.MaxGoalKcal)
}

// TodayTargetKcal mirrors todayTargetKcal:
// round(goalKcal * pct / 100) → round to nearest 10 → clamp [0, maxGoalKcal].
func (g *KcalGoal) TodayTargetKcal(goalKcal, dayTargetPercent int) int {
	if goalKcal <= 0 {
		return 0
	}
	pct := stats.ClampInt(dayTargetPercent, 0, 100)
	v := stats.RoundInt(float64(goalKcal) * float64(pct) / 100)
	return stats.ClampInt(roundToNearest10(v), 0, g.Cfg.MaxGoalKcal)
}

// RoundToNearest10 mirrors _roundToNearest10.
func RoundToNearest10(value int) int { return roundToNearest10(value) }

func roundToNearest10(value int) int {
	if value <= 0 {
		return 0
	}
	return stats.RoundInt(float64(value)/10) * 10
}

// Algorithm mirrors ActivityScoreAlgorithm.
type Algorithm struct {
	Cfg      config.Activity
	KcalGoal *KcalGoal
}

// New returns an Algorithm with the given config (default if zero).
func New(cfg config.Activity) *Algorithm {
	return &Algorithm{Cfg: cfg, KcalGoal: &KcalGoal{Cfg: cfg}}
}

// PreferWearable mirrors preferWearable: BRACELET records if any, else RING,
// else all.
func (a *Algorithm) PreferWearable(records []StepsRecord) []StepsRecord {
	var bracelet []StepsRecord
	for _, r := range records {
		if r.Device == domain.DeviceBracelet {
			bracelet = append(bracelet, r)
		}
	}
	if len(bracelet) > 0 {
		return bracelet
	}
	var ring []StepsRecord
	for _, r := range records {
		if r.Device == domain.DeviceRing {
			ring = append(ring, r)
		}
	}
	if len(ring) > 0 {
		return ring
	}
	return records
}

// Aggregated mirrors the ({steps, calories, distance}) record.
type Aggregated struct {
	Steps    int
	Calories float64
	Distance float64
}

// AggregateSteps mirrors aggregateSteps: sort by timestamp asc; PEAK (max)
// of value/calories/distance; steps truncated to int.
func (a *Algorithm) AggregateSteps(records []StepsRecord) Aggregated {
	if len(records) == 0 {
		return Aggregated{}
	}
	sorted := append([]StepsRecord(nil), records...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Timestamp < sorted[j].Timestamp })

	var stepsPeak, calories, distance float64
	for _, r := range sorted {
		if r.Value > stepsPeak {
			stepsPeak = r.Value
		}
		if r.Calories > calories {
			calories = r.Calories
		}
		if r.DistanceM > distance {
			distance = r.DistanceM
		}
	}
	return Aggregated{Steps: int(stepsPeak), Calories: calories, Distance: distance}
}

// DayTargetPercent mirrors dayTargetPercent:
// readiness <= 0 → 100; else round(readiness*w + neutral*(1-w)).clamp(30,90).
func (a *Algorithm) DayTargetPercent(readinessScore int) int {
	if readinessScore <= 0 {
		return 100
	}
	w := stats.Clamp(a.Cfg.DayTargetReadinessWeight, 0.0, 1.0)
	blended := float64(readinessScore)*w +
		float64(a.Cfg.DayTargetNeutral)*(1.0-w)
	return stats.ClampInt(stats.RoundInt(blended), a.Cfg.DayTargetMin, a.Cfg.DayTargetMax)
}

// ScoreFromKcal mirrors scoreFromKcal: round(100 * totalKcal / goalKcal)
// .clamp(0,100); goalKcal <= 0 → 100.
func (a *Algorithm) ScoreFromKcal(totalKcal, goalKcal int) int {
	if goalKcal <= 0 {
		return 100
	}
	return stats.ClampInt(stats.RoundInt(100.0*float64(totalKcal)/float64(goalKcal)), 0, 100)
}

// DayResult mirrors the activity score service output map.
type DayResult struct {
	ActivityScore    int
	TotalSteps       int
	TotalKcal        int
	WearableDayKcal  int
	SessionKcal      int
	GoalSteps        int
	GoalKcal         int
	DayTargetPercent int
	TodayTargetKcal  int
	ZoneStartPercent int
	ZoneEndPercent   int
}

// Calculate runs the pure activity pipeline for a day.
//
// wearableDayKcal = aggregated wearable kcal (rounded); sessionKcal = sum of
// completed-session kcal in the day; goalSteps: parameter limitMax if > 0
// else demographic prior (the engine resolves it); readiness from F-03.
func (a *Algorithm) Calculate(
	wearableDayKcal float64,
	sessionKcal int,
	goalSteps int,
	readinessScore int,
) DayResult {
	goal := goalSteps
	if goal <= 0 {
		goal = a.Cfg.DefaultGoalSteps
	}
	goalKcal := a.KcalGoal.GoalKcalFromSteps(goal)
	totalKcal := stats.ClampInt(stats.RoundInt(wearableDayKcal)+sessionKcal, 0, 100000)
	dayTarget := a.DayTargetPercent(readinessScore)
	todayTargetKcal := a.KcalGoal.TodayTargetKcal(goalKcal, dayTarget)
	score := a.ScoreFromKcal(totalKcal, goalKcal)
	return DayResult{
		ActivityScore:    score,
		WearableDayKcal:  stats.RoundInt(wearableDayKcal),
		SessionKcal:      sessionKcal,
		TotalKcal:        totalKcal,
		GoalSteps:        goal,
		GoalKcal:         goalKcal,
		DayTargetPercent: dayTarget,
		TodayTargetKcal:  todayTargetKcal,
		ZoneStartPercent: stats.ClampInt(dayTarget-10, 0, 100),
		ZoneEndPercent:   stats.ClampInt(dayTarget+10, 0, 100),
	}
}
