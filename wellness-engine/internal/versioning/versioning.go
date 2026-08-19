// Formula versioning — stable identifiers and active-version selection.
//
// Design per docs/formula-versioning.md. No persistence yet: the registry is
// in-memory and the ACTIVE version is defined in ONE centralized place
// (DefaultRegistry); a future database-backed registry can replace the
// selection without touching the calculation core.
package versioning

import "time"

// Key is a stable formula identifier (audit IDs F-01..F-09).
type Key string

const (
	KeySleep     Key = "sleep"      // F-01
	KeyStress    Key = "stress"     // F-02
	KeyReadiness Key = "readiness"  // F-03
	KeyActivity  Key = "activity"   // F-04
	KeyGoalSteps Key = "goal_steps" // F-08
	KeyGoalSleep Key = "goal_sleep" // F-09 (bedtime + sleep target)
)

// Status mirrors the DRAFT/ACTIVE/RETIRED lifecycle.
type Status int

const (
	StatusDraft Status = iota
	StatusActive
	StatusRetired
)

func (s Status) String() string {
	switch s {
	case StatusDraft:
		return "DRAFT"
	case StatusActive:
		return "ACTIVE"
	case StatusRetired:
		return "RETIRED"
	}
	return "UNKNOWN"
}

// FormulaVersion is the typed metadata for one version of one formula.
type FormulaVersion struct {
	Key           Key
	Version       int
	Status        Status
	Name          string
	Description   string
	EffectiveFrom time.Time
}

// Registry resolves formulas by key + version and exposes the ACTIVE
// version. It is immutable after construction (no hidden mutable globals).
type Registry struct {
	versions map[Key][]FormulaVersion
	active   map[Key]FormulaVersion
}

// NewRegistry builds a registry from the given versions. The ACTIVE version
// per key is the highest-versioned entry with StatusActive.
func NewRegistry(versions []FormulaVersion) *Registry {
	r := &Registry{
		versions: make(map[Key][]FormulaVersion),
		active:   make(map[Key]FormulaVersion),
	}
	for _, v := range versions {
		r.versions[v.Key] = append(r.versions[v.Key], v)
		if v.Status == StatusActive {
			cur, ok := r.active[v.Key]
			if !ok || v.Version > cur.Version {
				r.active[v.Key] = v
			}
		}
	}
	return r
}

// DefaultRegistry returns the parity registry: every formula at version 1,
// ACTIVE. This is the single source of the active-version selection until a
// database-backed registry replaces it (STAGE 14+).
func DefaultRegistry() *Registry {
	eff := time.Date(2026, 8, 19, 0, 0, 0, 0, time.UTC)
	return NewRegistry([]FormulaVersion{
		{Key: KeySleep, Version: 1, Status: StatusActive, Name: "Sleep Score", Description: "F-01 discount model (ritma-app parity)", EffectiveFrom: eff},
		{Key: KeyStress, Version: 1, Status: StatusActive, Name: "Stress Score", Description: "F-02 HRV log-domain sigmoid (ritma-app parity)", EffectiveFrom: eff},
		{Key: KeyReadiness, Version: 1, Status: StatusActive, Name: "Readiness Score", Description: "F-03 weighted blend + caps (ritma-app parity)", EffectiveFrom: eff},
		{Key: KeyActivity, Version: 1, Status: StatusActive, Name: "Activity Score", Description: "F-04 kcal goal (ritma-app parity)", EffectiveFrom: eff},
		{Key: KeyGoalSteps, Version: 1, Status: StatusActive, Name: "Steps Goal Auto-Update", Description: "F-08 adaptive steps goal (ritma-app parity)", EffectiveFrom: eff},
		{Key: KeyGoalSleep, Version: 1, Status: StatusActive, Name: "Sleep Config Auto-Update", Description: "F-09 bedtime + duration goal (ritma-app parity)", EffectiveFrom: eff},
	})
}

// Get resolves a specific (key, version); ok=false when unknown.
func (r *Registry) Get(key Key, version int) (FormulaVersion, bool) {
	for _, v := range r.versions[key] {
		if v.Version == version {
			return v, true
		}
	}
	return FormulaVersion{}, false
}

// Active resolves the active version for a key.
func (r *Registry) Active(key Key) FormulaVersion {
	return r.active[key]
}

// EngineVersion is the build-injected engine version (ldflags
// -X .../versioning.EngineVersion=v1.2.3). It is metadata only — it NEVER
// participates in config hashing or mathematical output.
var EngineVersion = "dev"
