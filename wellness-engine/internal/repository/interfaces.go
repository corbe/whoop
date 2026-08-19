// Repository interfaces (STAGE 14 §9). Implementations: postgres adapter.
// The pure engine packages never import this package.
package repository

import (
	"context"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/versioning"
)

// Run is one persisted calculation revision.
type Run struct {
	RunID            int64
	PersonID         string
	LogicalDay       time.Time // date, device-local semantics
	Timezone         string
	InputFingerprint string
	ConfigHash       string
	EngineVersion    string
	FormulaVersions  map[string]int
	QualityJSON      []byte // warnings + missing (JSONB payload)
	CalculatedAt     time.Time
	ReplacesRunID    *int64
}

// Score is one persisted daily score row.
type Score struct {
	RunID          int64
	PersonID       string
	LogicalDay     time.Time
	FormulaKey     string
	FormulaVersion int
	ConfigHash     string
	Score          int
	Explanation    []byte // JSONB payload (explain.Explanation)
	IsCurrent      bool
}

// Goal is one goal-state history row.
type Goal struct {
	PersonID       string
	GoalKey        string // goal_steps | goal_sleep
	Value          int
	BedTimeMinutes *int
	Reason         string
	Source         string // auto | manual | seed
	FormulaKey     string
	ConfigHash     string
	RunID          *int64
	AppliedAt      time.Time
}

// BaselineSnapshot captures the baseline state a run consumed.
type BaselineSnapshot struct {
	PersonID   string
	LogicalDay time.Time
	Metrics    []byte // JSONB (values + sample counts + confidences)
	RunID      int64
}

// ErrDuplicateRun signals an idempotent replay (no rows written).
var ErrDuplicateRun = errDuplicate("duplicate run: same semantic calculation already persisted")

type errDuplicate string

func (e errDuplicate) Error() string { return string(e) }

// Store is the full persistence boundary for calculation bundles.
type Store interface {
	// PersistBundle atomically persists one CalculationBundle as a new
	// calculation run (or returns ErrDuplicateRun for an idempotent replay).
	PersistBundle(ctx context.Context, in Input, bundle Bundle) (*Run, error)
	// CurrentScore returns the current score row for person/day/formula.
	CurrentScore(ctx context.Context, personID string, day time.Time, formulaKey string) (*Score, error)
	// ScoreHistory returns all revisions, newest first.
	ScoreHistory(ctx context.Context, personID string, day time.Time, formulaKey string) ([]Score, error)
	// RunRevisions returns the run chain for person/day (newest first).
	RunRevisions(ctx context.Context, personID string, day time.Time) ([]Run, error)
	// CurrentGoal returns the current goal for person/key.
	CurrentGoal(ctx context.Context, personID string, goalKey string) (*Goal, error)
	// GoalHistory returns all goal changes, newest first.
	GoalHistory(ctx context.Context, personID string, goalKey string) ([]Goal, error)
	// CurrentBaseline returns the newest baseline snapshot for the person.
	CurrentBaseline(ctx context.Context, personID string) (*BaselineSnapshot, error)
}

// Input is the minimal bundle-persistence input (fingerprint source).
type Input struct {
	PersonID string
	Day      time.Time
	Timezone string
	// Fingerprint of the engine input (engine.Input.Fingerprint()).
	Fingerprint string
}

// Bundle is the persistence projection of engine.CalculationBundle.
type Bundle struct {
	ConfigHash      string
	EngineVersion   string
	FormulaVersions map[string]int
	CalculatedAt    time.Time
	QualityJSON     []byte
	Scores          []Score // full rows incl. explanation payload
	GoalChanges     []Goal  // only when the run applied a goal update
	Baseline        *BaselineSnapshot
}

// RegistryStore resolves ACTIVE formula versions from the DB.
type RegistryStore interface {
	// ActiveVersion returns the ACTIVE version for a formula key.
	ActiveVersion(ctx context.Context, key versioning.Key) (versioning.FormulaVersion, error)
}
