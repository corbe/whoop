// Application service layer (STAGE 17.1) — the boundary between HTTP and
// the pure engine + persistence. HTTP handlers never orchestrate engine
// internals or SQL directly.
package application

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/persistence"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/repository"
)

// RawInputProvider resolves a person/day's raw physiological input from
// canonical storage (mode A of the Stage 16 design). Mode B (stateless)
// passes the engine.Input directly to CalculateDay.
type RawInputProvider interface {
	LoadDay(ctx context.Context, personID string, day time.Time) (engine.Input, error)
}

// CalculateResult is the outcome of one calculate request.
type CalculateResult struct {
	// Replay is true when the same semantic calculation already existed
	// (idempotent replay → HTTP 200; new → 201).
	Replay bool
	Run    *repository.Run
	Bundle *engine.CalculationBundle
}

// WellnessService implements the Stage 16 contract.
type WellnessService struct {
	cfg      engine.Configs
	store    repository.Store
	provider RawInputProvider // optional (mode A)
}

// New builds a service. provider may be nil (mode B only).
func New(store repository.Store, provider RawInputProvider, cfg engine.Configs) *WellnessService {
	return &WellnessService{cfg: cfg, store: store, provider: provider}
}

// Configs exposes the effective configuration (health/readiness metadata).
func (s *WellnessService) Configs() engine.Configs { return s.cfg }

// CalculateDay runs the full pipeline and persists the bundle atomically.
// raw nil → mode A (RawInputProvider); non-nil → mode B (stateless input).
func (s *WellnessService) CalculateDay(ctx context.Context, personID string, day time.Time, raw *engine.Input) (*CalculateResult, error) {
	if personID == "" {
		return nil, domain.InvalidInput("person id empty")
	}
	var in engine.Input
	if raw != nil {
		in = *raw
	} else {
		if s.provider == nil {
			return nil, domain.InvalidInput("no input provider configured")
		}
		loaded, err := s.provider.LoadDay(ctx, personID, day)
		if err != nil {
			return nil, fmt.Errorf("resolve input: %w", err)
		}
		in = loaded
	}
	in.PersonID = personID
	if in.Date.IsZero() {
		in.Date = day
	}
	if in.Location == nil {
		in.Location = time.Local
	}

	bundle, err := engine.CalculateDayDetailed(in, s.cfg)
	if err != nil {
		return nil, err
	}
	rin, rb, err := persistence.ProjectBundle(in, bundle)
	if err != nil {
		return nil, fmt.Errorf("project bundle: %w", err)
	}
	run, err := s.store.PersistBundle(ctx, rin, rb)
	if errors.Is(err, repository.ErrDuplicateRun) {
		return &CalculateResult{Replay: true, Run: run, Bundle: bundle}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("persist: %w", err)
	}
	return &CalculateResult{Replay: false, Run: run, Bundle: bundle}, nil
}

// GetDailyScores returns the current scores for all four formulas (nil when
// no current row exists for a formula).
func (s *WellnessService) GetDailyScores(ctx context.Context, personID string, day time.Time) (map[string]*repository.Score, error) {
	out := make(map[string]*repository.Score, 4)
	for _, key := range []string{"sleep", "stress", "readiness", "activity"} {
		sc, err := s.store.CurrentScore(ctx, personID, day, key)
		if err != nil {
			return nil, err
		}
		if sc != nil {
			out[key] = sc
		}
	}
	return out, nil
}

// GetScoreDetail returns the current score + explanation payload.
func (s *WellnessService) GetScoreDetail(ctx context.Context, personID string, day time.Time, formulaKey string) (*repository.Score, error) {
	if !validFormula(formulaKey) {
		return nil, domain.InvalidInput("unknown formula: %s", formulaKey)
	}
	sc, err := s.store.CurrentScore(ctx, personID, day, formulaKey)
	if err != nil {
		return nil, err
	}
	if sc == nil {
		return nil, domain.NoData("no current score for " + formulaKey)
	}
	return sc, nil
}

// GetRunRevisions returns the run chain for a person/day (newest first).
func (s *WellnessService) GetRunRevisions(ctx context.Context, personID string, day time.Time) ([]repository.Run, error) {
	return s.store.RunRevisions(ctx, personID, day)
}

// GetScoreHistory returns revisions newest-first, each enriched with run
// metadata (engine_version, calculated_at, replaces_run_id, fingerprint).
func (s *WellnessService) GetScoreHistory(ctx context.Context, personID string, day time.Time, formulaKey string) ([]HistoryEntry, error) {
	if !validFormula(formulaKey) {
		return nil, domain.InvalidInput("unknown formula: %s", formulaKey)
	}
	scores, err := s.store.ScoreHistory(ctx, personID, day, formulaKey)
	if err != nil {
		return nil, err
	}
	runs, err := s.store.RunRevisions(ctx, personID, day)
	if err != nil {
		return nil, err
	}
	runMeta := make(map[int64]repository.Run, len(runs))
	for _, r := range runs {
		runMeta[r.RunID] = r
	}
	out := make([]HistoryEntry, 0, len(scores))
	for _, sc := range scores {
		out = append(out, HistoryEntry{
			Score:            sc,
			EngineVersion:    runMeta[sc.RunID].EngineVersion,
			CalculatedAt:     runMeta[sc.RunID].CalculatedAt,
			ReplacesRunID:    runMeta[sc.RunID].ReplacesRunID,
			InputFingerprint: runMeta[sc.RunID].InputFingerprint,
		})
	}
	return out, nil
}

// HistoryEntry is a score revision enriched with run metadata.
type HistoryEntry struct {
	Score            repository.Score
	EngineVersion    string
	CalculatedAt     time.Time
	ReplacesRunID    *int64
	InputFingerprint string
}

// GetCurrentGoals returns both current goals (nil entries when unset).
func (s *WellnessService) GetCurrentGoals(ctx context.Context, personID string) (map[string]*repository.Goal, error) {
	out := make(map[string]*repository.Goal, 2)
	for _, key := range []string{"goal_steps", "goal_sleep"} {
		g, err := s.store.CurrentGoal(ctx, personID, key)
		if err != nil {
			return nil, err
		}
		if g != nil {
			out[key] = g
		}
	}
	return out, nil
}

// GetGoalHistory returns all goal changes for a key, newest first.
func (s *WellnessService) GetGoalHistory(ctx context.Context, personID string, goalKey string) ([]repository.Goal, error) {
	if goalKey != "goal_steps" && goalKey != "goal_sleep" {
		return nil, domain.InvalidInput("unknown goal key: %s", goalKey)
	}
	return s.store.GoalHistory(ctx, personID, goalKey)
}

// GetCurrentBaseline returns the newest baseline snapshot.
func (s *WellnessService) GetCurrentBaseline(ctx context.Context, personID string) (*repository.BaselineSnapshot, error) {
	return s.store.CurrentBaseline(ctx, personID)
}

func validFormula(key string) bool {
	switch key {
	case "sleep", "stress", "readiness", "activity":
		return true
	}
	return false
}
