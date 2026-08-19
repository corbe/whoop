package priors

import (
	"testing"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/golden"
)

func TestGoldenPriorsOracle(t *testing.T) {
	oracle, err := golden.Load()
	if err != nil {
		t.Fatal(err)
	}
	cfg := DefaultConfig()

	// steps prior: age65 6000, age25 7500, bmi30 6500, female 7000,
	// male 7500, all(age20,bmi31,M) 7500
	{
		entry := oracle["demographic_steps_prior"].(map[string]any)
		out := entry["output"].(map[string]any)
		age65 := 65
		age25 := 25
		age40 := 40
		age20 := 20
		bmi31 := 31.0
		bmi25 := 25.0
		F := "F"
		M := "M"

		cases := []struct {
			name string
			got  int
		}{
			{"age65", PriorDailySteps(cfg, &age65, nil, nil)},
			{"age25", PriorDailySteps(cfg, &age25, nil, nil)},
			{"bmi30", PriorDailySteps(cfg, &age40, &bmi31, nil)},
			{"female", PriorDailySteps(cfg, &age40, &bmi25, &F)},
			{"male", PriorDailySteps(cfg, &age40, &bmi25, &M)},
			{"all", PriorDailySteps(cfg, &age20, &bmi31, &M)},
		}
		for _, c := range cases {
			want := int(out[c.name].(float64))
			if c.got != want {
				t.Errorf("%s: got %d want %d", c.name, c.got, want)
			}
		}
	}

	// sleep target prior: age20 510, age70 450, age40 480
	{
		entry := oracle["demographic_sleep_prior"].(map[string]any)
		out := entry["output"].(map[string]any)
		age20, age70, age40 := 20, 70, 40
		if got := PriorSleepTargetMinutes(cfg, &age20); got != int(out["age20"].(float64)) {
			t.Errorf("age20: got %d want %v", got, out["age20"])
		}
		if got := PriorSleepTargetMinutes(cfg, &age70); got != int(out["age70"].(float64)) {
			t.Errorf("age70: got %d want %v", got, out["age70"])
		}
		if got := PriorSleepTargetMinutes(cfg, &age40); got != int(out["age40"].(float64)) {
			t.Errorf("age40: got %d want %v", got, out["age40"])
		}
	}
}

func TestPriorsExtras(t *testing.T) {
	cfg := DefaultConfig()
	if got := PriorBedTimeMinutes(cfg); got != 1320 {
		t.Errorf("bedtime: got %d want 1320", got)
	}
	age65 := 65
	age30 := 30
	if got := MaxDailyStepsForAge(cfg, &age65); got != 12000 {
		t.Errorf("max age65: got %d want 12000", got)
	}
	if got := MaxDailyStepsForAge(cfg, &age30); got != 15000 {
		t.Errorf("max age30: got %d want 15000", got)
	}
	// gender normalization: lowercase/whitespace tolerated
	gender := " mulher "
	if got := PriorDailySteps(cfg, nil, nil, &gender); got != 7000 {
		t.Errorf("' mulher ' : got %d want 7000 (7000-250=6750→7000)", got)
	}
}
