// Calculation configuration — port of lib/core/scores/score_calibration.dart.
//
// The defaults below are EXACTLY ScoreCalibration.current (parity anchor for
// the golden dataset). Per docs/formula-configuration-decisions.md these are
// the CONFIGURABLE parameters (weights, thresholds, windows, clamps); the
// algorithm structure lives in the scoring packages.
//
// Dead Dart parameters are NOT ported: instantFallbackHours,
// idealStagePctMin/Max, highStagePct, batteryDepletedPct, nightStartHour,
// nightEndHour, rhrBaselineWindowDays (see decisions doc §3).
package config

// Sleep mirrors SleepScoreCalibration.
type Sleep struct {
	DefaultBedTimeMinutes     int
	DefaultSleepTargetMinutes int
	OnTimeThresholdMin        int
	SomewhatThresholdMin      int
	MaxBedTimeDiscount        float64
	MaxDurationDiscount       float64
	BedLateCoef1              float64
	BedLateCoef2              float64
	EarlyCoefLight            float64
	EarlyCoefHeavy            float64
	DurationOverCoefLight     float64
	DurationOverCoefHeavy     float64
	DurationCoef1             float64
	DurationCoef2             float64
	DurationCoef3             float64
}

// DefaultSleep returns the Dart defaults (score_calibration.dart:24-70).
func DefaultSleep() Sleep {
	return Sleep{
		DefaultBedTimeMinutes:     1320, // 22:00
		DefaultSleepTargetMinutes: 480,  // 8h
		OnTimeThresholdMin:        30,
		SomewhatThresholdMin:      90,
		MaxBedTimeDiscount:        15,
		MaxDurationDiscount:       65,
		BedLateCoef1:              0.0899,
		BedLateCoef2:              0.1333,
		EarlyCoefLight:            0.3,
		EarlyCoefHeavy:            0.65,
		DurationOverCoefLight:     0.4,
		DurationOverCoefHeavy:     0.75,
		DurationCoef1:             0.2500,
		DurationCoef2:             0.2666,
		DurationCoef3:             0.2777,
	}
}

// Stress mirrors StressScoreCalibration.
type Stress struct {
	DefaultLnSd          float64
	MinLnSd              float64
	MaxLnSd              float64
	ZClampMin            float64
	ZClampMax            float64
	MinScoreWithData     float64
	BaselineWindowDays   int
	MinDaysRequired      int
	RollingTrendDays     int
	InstantWindowMinutes []int
	SigmoidMidpoint      float64
	SigmoidSteepness     float64
	SigmoidSpan          float64
}

// DefaultStress returns the Dart defaults (score_calibration.dart:72-104).
func DefaultStress() Stress {
	return Stress{
		DefaultLnSd:          0.22,
		MinLnSd:              0.20,
		MaxLnSd:              0.40,
		ZClampMin:            -1.0,
		ZClampMax:            3.0,
		MinScoreWithData:     12.0,
		BaselineWindowDays:   21,
		MinDaysRequired:      5,
		RollingTrendDays:     7,
		InstantWindowMinutes: []int{15, 60, 180},
		SigmoidMidpoint:      2.0,
		SigmoidSteepness:     0.72,
		SigmoidSpan:          83.0,
	}
}

// Readiness mirrors ReadinessScoreCalibration.
type Readiness struct {
	WeightSleep              float64
	WeightRecovery           float64
	WeightRhr                float64
	WeightSpo2               float64
	WeightFatigue            float64
	SleepTodayWeight         float64
	SleepHistoryWeight       float64
	FatigueIdentityThreshold int
	RhrZeroRatio             float64
	FatigueLookbackDays      int
	SleepHistoryDays         int
	CapSleep30               int
	CapSleep40               int
	CapSleep50               int
	CapSleep60               int
}

// DefaultReadiness returns the Dart defaults (score_calibration.dart:106-142).
func DefaultReadiness() Readiness {
	return Readiness{
		WeightSleep:              0.35,
		WeightRecovery:           0.25,
		WeightRhr:                0.15,
		WeightSpo2:               0.10,
		WeightFatigue:            0.15,
		SleepTodayWeight:         0.70,
		SleepHistoryWeight:       0.30,
		FatigueIdentityThreshold: 65,
		RhrZeroRatio:             1.12,
		FatigueLookbackDays:      3,
		SleepHistoryDays:         4,
		CapSleep30:               35,
		CapSleep40:               45,
		CapSleep50:               58,
		CapSleep60:               72,
	}
}

// Activity mirrors ActivityScoreCalibration.
type Activity struct {
	DefaultGoalSteps         int
	KcalPerStep              float64
	MinGoalKcal              int
	MaxGoalKcal              int
	DayTargetReadinessWeight float64
	DayTargetNeutral         int
	DayTargetMin             int
	DayTargetMax             int
}

// DefaultActivity returns the Dart defaults (score_calibration.dart:144-166).
func DefaultActivity() Activity {
	return Activity{
		DefaultGoalSteps:         7000,
		KcalPerStep:              0.04,
		MinGoalKcal:              150,
		MaxGoalKcal:              800,
		DayTargetReadinessWeight: 0.55,
		DayTargetNeutral:         55,
		DayTargetMin:             30,
		DayTargetMax:             90,
	}
}

// Baseline holds the baseline constants (wellness_baselines.dart:23-25).
type Baseline struct {
	WindowDays        int
	PriorRestingHrBpm float64
	PriorNightSpo2Pct float64
}

// DefaultBaseline returns the Dart constants.
func DefaultBaseline() Baseline {
	return Baseline{
		WindowDays:        30,
		PriorRestingHrBpm: 65.0,
		PriorNightSpo2Pct: 96.0,
	}
}
