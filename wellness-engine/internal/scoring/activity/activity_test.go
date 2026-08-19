package activity

import (
	"testing"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/golden"
)

func TestGoldenActivityOracle(t *testing.T) {
	oracle, err := golden.Load()
	if err != nil {
		t.Fatal(err)
	}
	a := New(config.DefaultActivity())

	// goalKcal from steps: [7000,5000,3000,20000,0] → [280,200,150,800,150]
	{
		entry := oracle["activity_goal_kcal"].(map[string]any)
		inputs := entry["input"].(map[string]any)["goalSteps"].([]any)
		output := entry["output"].(map[string]any)
		for _, iv := range inputs {
			s := int(iv.(float64))
			got := a.KcalGoal.GoalKcalFromSteps(s)
			want := int(output[itoa(s)].(float64))
			if got != want {
				t.Errorf("goalKcal(%d): got %d want %d", s, got, want)
			}
		}
	}

	// dayTarget: readiness [0,30,55,80,100] → [100,41,55,69,80]
	{
		entry := oracle["activity_day_target"].(map[string]any)
		inputs := entry["input"].(map[string]any)["readiness"].([]any)
		output := entry["output"].(map[string]any)
		for _, iv := range inputs {
			r := int(iv.(float64))
			got := a.DayTargetPercent(r)
			want := int(output[itoa(r)].(float64))
			if got != want {
				t.Errorf("dayTarget(%d): got %d want %d", r, got, want)
			}
		}
	}

	// todayTargetKcal: goal 280, pct [30,55,90] → [80,150,250]
	{
		entry := oracle["activity_today_target_kcal"].(map[string]any)
		inputs := entry["input"].(map[string]any)["dayTargetPercent"].([]any)
		output := entry["output"].(map[string]any)
		for _, pv := range inputs {
			p := int(pv.(float64))
			got := a.KcalGoal.TodayTargetKcal(280, p)
			want := int(output[itoa(p)].(float64))
			if got != want {
				t.Errorf("todayTarget(%d): got %d want %d", p, got, want)
			}
		}
	}

	// scoreFromKcal: kcal [0,140,280,420,999] vs goal 280 → [0,50,100,100,100]
	{
		entry := oracle["activity_score_from_kcal"].(map[string]any)
		inputs := entry["input"].(map[string]any)["totalKcal"].([]any)
		output := entry["output"].(map[string]any)
		for _, kv := range inputs {
			k := int(kv.(float64))
			got := a.ScoreFromKcal(k, 280)
			want := int(output[itoa(k)].(float64))
			if got != want {
				t.Errorf("scoreFromKcal(%d): got %d want %d", k, got, want)
			}
		}
	}

	// aggregateSteps: 3 bracelet records, peak 800/32/640
	{
		entry := oracle["activity_aggregate_peak"].(map[string]any)
		records := []StepsRecord{
			{Value: 100, Calories: 4, DistanceM: 80, Timestamp: 1000, Device: domain.DeviceBracelet},
			{Value: 350, Calories: 14, DistanceM: 280, Timestamp: 2000, Device: domain.DeviceBracelet},
			{Value: 800, Calories: 32, DistanceM: 640, Timestamp: 3000, Device: domain.DeviceBracelet},
		}
		got := a.AggregateSteps(records)
		out := entry["output"].(map[string]any)
		if got.Steps != int(out["steps"].(float64)) {
			t.Errorf("steps: got %d want %v", got.Steps, out["steps"])
		}
		if got.Calories != out["calories"].(float64) || got.Distance != out["distance"].(float64) {
			t.Errorf("cal/dist: got %v/%v want %v/%v", got.Calories, got.Distance, out["calories"], out["distance"])
		}
	}

	// preferWearable: RING + BRACELET → BRACELET wins; aggregate peak 800
	{
		entry := oracle["activity_prefer_wearable"].(map[string]any)
		records := []StepsRecord{
			{Value: 700, Calories: 28, DistanceM: 560, Timestamp: 1000, Device: domain.DeviceRing},
			{Value: 100, Calories: 4, DistanceM: 80, Timestamp: 1000, Device: domain.DeviceBracelet},
			{Value: 800, Calories: 32, DistanceM: 640, Timestamp: 3000, Device: domain.DeviceBracelet},
		}
		pref := a.PreferWearable(records)
		for _, r := range pref {
			if r.Device != domain.DeviceBracelet {
				t.Errorf("preferWearable: got %s, want BRACELET only", r.Device)
			}
		}
		agg := a.AggregateSteps(pref)
		out := entry["output"].(map[string]any)["aggregate"].(map[string]any)
		if agg.Steps != int(out["steps"].(float64)) {
			t.Errorf("aggregate steps: got %d want %v", agg.Steps, out["steps"])
		}
	}
}

func TestCalculatePipeline(t *testing.T) {
	a := New(config.DefaultActivity())
	// wearable 100 kcal, session 50, goal 7000, readiness 55
	res := a.Calculate(100, 50, 7000, 55)
	if res.GoalKcal != 280 {
		t.Errorf("goalKcal: got %d want 280", res.GoalKcal)
	}
	if res.TotalKcal != 150 {
		t.Errorf("totalKcal: got %d want 150", res.TotalKcal)
	}
	if res.ActivityScore != 54 {
		t.Errorf("score: got %d want 54 (round(100*150/280))", res.ActivityScore)
	}
	if res.DayTargetPercent != 55 {
		t.Errorf("dayTarget: got %d want 55", res.DayTargetPercent)
	}
	if res.ZoneStartPercent != 45 || res.ZoneEndPercent != 65 {
		t.Errorf("zone: got %d..%d want 45..65", res.ZoneStartPercent, res.ZoneEndPercent)
	}
	// readiness 0 → dayTarget 100
	res = a.Calculate(280, 0, 7000, 0)
	if res.DayTargetPercent != 100 || res.ActivityScore != 100 {
		t.Errorf("readiness 0: got dayTarget=%d score=%d want 100/100", res.DayTargetPercent, res.ActivityScore)
	}
	// goalSteps 0 → default 7000
	res = a.Calculate(0, 0, 0, 55)
	if res.GoalSteps != 7000 || res.ActivityScore != 0 {
		t.Errorf("no data: got goal=%d score=%d", res.GoalSteps, res.ActivityScore)
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var buf [8]byte
	pos := len(buf)
	for i > 0 {
		pos--
		buf[pos] = byte('0' + i%10)
		i /= 10
	}
	return string(buf[pos:])
}
