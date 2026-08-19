// Demographic priors — port of DemographicPrior (F-10).
//
// Source: lib/core/scores/demographic_prior.dart @ 5b1698f. Pure rules only;
// profile loading (WellnessDemographicsLoader) lives in the engine.
package priors

import (
	"strings"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/stats"
)

// Config mirrors PersonalizedBaselineCalibration (the fields this package
// consumes).
type Config struct {
	BaseDailySteps            int
	MinDailySteps             int
	MaxDailySteps             int
	DefaultBedTimeMinutes     int
	DefaultSleepTargetMinutes int
	MinSleepTargetMinutes     int
	MaxSleepTargetMinutes     int
}

// DefaultConfig mirrors the PersonalizedBaselineCalibration defaults
// (score_calibration.dart:169-205).
func DefaultConfig() Config {
	return Config{
		BaseDailySteps:            7000,
		MinDailySteps:             3000,
		MaxDailySteps:             15000,
		DefaultBedTimeMinutes:     1320,
		DefaultSleepTargetMinutes: 480,
		MinSleepTargetMinutes:     300,
		MaxSleepTargetMinutes:     600,
	}
}

// PriorDailySteps mirrors priorDailySteps:
// base 7000; age>=65 −1000, age<=25 +500; bmi>=30 −500; F −250, M +250;
// clamp [min, max]; round to nearest 500 (<=0 → 7000).
func PriorDailySteps(cfg Config, ageYears *int, bmi *float64, gender *string) int {
	steps := cfg.BaseDailySteps
	if ageYears != nil {
		if *ageYears >= 65 {
			steps -= 1000
		} else if *ageYears <= 25 {
			steps += 500
		}
	}
	if bmi != nil && *bmi >= 30 {
		steps -= 500
	}
	if gender != nil {
		switch g := strings.ToUpper(strings.TrimSpace(*gender)); g {
		case "F", "FEMALE", "MULHER":
			steps -= 250
		case "M", "MALE", "HOMEM":
			steps += 250
		}
	}
	return roundStepsToNearest500(stats.ClampInt(steps, cfg.MinDailySteps, cfg.MaxDailySteps))
}

// PriorSleepTargetMinutes mirrors priorSleepTargetMinutes:
// 480; age<=25 +30; age>=65 −30; clamp [300, 600].
func PriorSleepTargetMinutes(cfg Config, ageYears *int) int {
	minutes := cfg.DefaultSleepTargetMinutes
	if ageYears != nil {
		if *ageYears <= 25 {
			minutes += 30
		} else if *ageYears >= 65 {
			minutes -= 30
		}
	}
	return stats.ClampInt(minutes, cfg.MinSleepTargetMinutes, cfg.MaxSleepTargetMinutes)
}

// PriorBedTimeMinutes mirrors priorBedTimeMinutes.
func PriorBedTimeMinutes(cfg Config) int { return cfg.DefaultBedTimeMinutes }

// MaxDailyStepsForAge mirrors maxDailyStepsForAge: >=65 → 12000, else max.
func MaxDailyStepsForAge(cfg Config, ageYears *int) int {
	if ageYears != nil && *ageYears >= 65 {
		return 12000
	}
	return cfg.MaxDailySteps
}

func roundStepsToNearest500(steps int) int {
	if steps <= 0 {
		return 7000
	}
	return stats.RoundInt(float64(steps)/500) * 500
}
