package versioning

import (
	"testing"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/goals"
)

func defaultSet() ConfigSet {
	return ConfigSet{
		Sleep:     config.DefaultSleep(),
		Stress:    config.DefaultStress(),
		Readiness: config.DefaultReadiness(),
		Activity:  config.DefaultActivity(),
		Baseline:  config.DefaultBaseline(),
		Goals:     goals.DefaultConfig(),
	}
}

func TestHashDeterministicSameConfig(t *testing.T) {
	h1 := HashConfig(defaultSet())
	h2 := HashConfig(defaultSet())
	if h1 != h2 {
		t.Errorf("same config object twice must hash identically:\n%s\n%s", h1, h2)
	}
}

func TestHashSemanticConstructionOrder(t *testing.T) {
	// Same semantic values, fields assigned in different order → same hash
	// (struct field order is fixed by the type; this proves the hash does
	// not depend on construction order).
	a := defaultSet()
	b := defaultSet()
	a.Activity = config.Activity{
		DayTargetMin:             30,
		MaxGoalKcal:              800,
		KcalPerStep:              0.04,
		DefaultGoalSteps:         7000,
		MinGoalKcal:              150,
		DayTargetNeutral:         55,
		DayTargetMax:             90,
		DayTargetReadinessWeight: 0.55,
	}
	b.Activity = config.DefaultActivity()
	if a.Activity != b.Activity {
		t.Fatal("test setup: structs must be equal")
	}
	if HashConfig(a) != HashConfig(b) {
		t.Error("semantically identical configs built differently must hash identically")
	}
}

func TestHashWeightChange(t *testing.T) {
	base := defaultSet()
	changed := defaultSet()
	changed.Readiness.WeightSleep = 0.40 // default 0.35
	if HashConfig(base) == HashConfig(changed) {
		t.Error("changed weight must change the hash")
	}
}

func TestHashThresholdChange(t *testing.T) {
	base := defaultSet()
	changed := defaultSet()
	changed.Sleep.OnTimeThresholdMin = 45 // default 30
	if HashConfig(base) == HashConfig(changed) {
		t.Error("changed threshold must change the hash")
	}
	// slice element change (instant windows are ordered semantics)
	changed2 := defaultSet()
	changed2.Stress.InstantWindowMinutes = []int{15, 60, 180, 360}
	if HashConfig(base) == HashConfig(changed2) {
		t.Error("changed instant-window slice must change the hash")
	}
}

func TestHashSliceOrderMatters(t *testing.T) {
	a := defaultSet()
	b := defaultSet()
	b.Stress.InstantWindowMinutes = []int{15, 180, 60} // different order
	if HashConfig(a) == HashConfig(b) {
		t.Error("reordered instant windows are different semantics → different hash")
	}
}

func TestHashExcludesRuntimeMetadata(t *testing.T) {
	// EngineVersion / calculated_at are NOT inputs to HashConfig — they are
	// metadata attached at result time. Changing them must not change the
	// hash; here we prove the hash function has no such inputs by
	// recomputing with different "environment" values (there is no way to
	// pass them — they are structurally excluded).
	_ = EngineVersion
	h := HashConfig(defaultSet())
	old := EngineVersion
	EngineVersion = "v99.99.99-buildX"
	if h != HashConfig(defaultSet()) {
		t.Error("hash must not depend on EngineVersion")
	}
	EngineVersion = old
}

func TestRegistry(t *testing.T) {
	r := DefaultRegistry()
	for _, key := range []Key{KeySleep, KeyStress, KeyReadiness, KeyActivity, KeyGoalSteps, KeyGoalSleep} {
		act := r.Active(key)
		if act.Version != 1 || act.Status != StatusActive {
			t.Errorf("%s: active must be v1 ACTIVE, got %+v", key, act)
		}
		if got, ok := r.Get(key, 1); !ok || got.Key != key {
			t.Errorf("%s: Get(key,1) failed", key)
		}
		if _, ok := r.Get(key, 99); ok {
			t.Errorf("%s: Get(key,99) must fail", key)
		}
	}
	if v2, ok := r.Get(KeySleep, 2); ok && v2.Status == StatusActive {
		t.Error("v2 must not exist as ACTIVE")
	}
}

func TestHashFormat(t *testing.T) {
	h := HashConfig(defaultSet())
	if len(h) != len("sha256:")+64 {
		t.Errorf("hash must be sha256:<64 hex>, got %q", h)
	}
}
