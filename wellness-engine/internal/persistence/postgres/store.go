// Store — Postgres implementation of repository.Store (STAGE 15).
//
// Atomicity: PersistBundle runs the whole bundle in ONE transaction
// (run + scores + goal history + baseline snapshot); a partial calculation
// can never become current. Idempotency: DB unique keys (run UNIQUE
// includes input_fingerprint+config_hash+engine_version; score UNIQUE
// (run_id, formula_key)); a replay returns repository.ErrDuplicateRun
// without writing. Revisions: a NEW run supersedes the previous current
// rows (is_current flip inside the tx); history rows stay immutable.
package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/repository"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/versioning"
)

// Store implements repository.Store over Postgres.
type Store struct {
	pool *pgxpool.Pool
}

// NewStore builds a Store (call Migrate once before use).
func NewStore(pool *pgxpool.Pool) *Store {
	return &Store{pool: pool}
}

// PersistBundle atomically persists one calculation bundle.
// Returns ErrDuplicateRun (repository) when the same semantic calculation
// already exists — nothing is written and no current row is disturbed.
func (s *Store) PersistBundle(ctx context.Context, in repository.Input, b repository.Bundle) (*repository.Run, error) {
	day := time.Date(in.Day.Year(), in.Day.Month(), in.Day.Day(), 0, 0, 0, 0, time.UTC)
	run := &repository.Run{
		PersonID:         in.PersonID,
		LogicalDay:       day,
		Timezone:         in.Timezone,
		InputFingerprint: in.Fingerprint,
		ConfigHash:       b.ConfigHash,
		EngineVersion:    b.EngineVersion,
		FormulaVersions:  b.FormulaVersions,
		QualityJSON:      b.QualityJSON,
		CalculatedAt:     b.CalculatedAt,
	}
	err := withTx(ctx, s.pool, func(tx pgx.Tx) error {
		// Serialize concurrent writers for the same (person, logical_day):
		// the is_current flip + insert must not race the partial unique
		// index. DB-level advisory lock (transaction-scoped), NOT an app
		// mutex. Last writer wins; the loser simply flips after the winner
		// commits (READ COMMITTED).
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`,
			in.PersonID+"|"+day.Format("2006-01-02")); err != nil {
			return fmt.Errorf("advisory lock: %w", err)
		}
		// previous current run → replaces_run_id (revision lineage)
		var prevID *int64
		row := tx.QueryRow(ctx, `
			SELECT r.run_id FROM wellness_daily_score d
			JOIN wellness_calculation_run r ON r.run_id = d.run_id
			WHERE d.person_id = $1 AND d.logical_day = $2 AND d.is_current
			LIMIT 1`, in.PersonID, day)
		var p int64
		if err := row.Scan(&p); err == nil {
			prevID = &p
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("resolve previous run: %w", err)
		}
		run.ReplacesRunID = prevID

		// idempotent insert of the run
		var runID int64
		err := tx.QueryRow(ctx, `
			INSERT INTO wellness_calculation_run
				(person_id, logical_day, timezone, input_fingerprint, config_hash,
				 engine_version, formula_versions, quality, calculated_at, replaces_run_id)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
			ON CONFLICT (person_id, logical_day, input_fingerprint, config_hash, engine_version)
			DO NOTHING
			RETURNING run_id`,
			in.PersonID, day, in.Timezone, in.Fingerprint, b.ConfigHash,
			b.EngineVersion, jsonMap(b.FormulaVersions), nullableJSON(b.QualityJSON),
			b.CalculatedAt, prevID).Scan(&runID)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("insert run: %w", err)
		}
		if errors.Is(err, pgx.ErrNoRows) {
			// idempotent replay: same semantic calculation already persisted
			if err := tx.QueryRow(ctx, `
				SELECT run_id FROM wellness_calculation_run
				WHERE person_id = $1 AND logical_day = $2 AND input_fingerprint = $3
				  AND config_hash = $4 AND engine_version = $5`,
				in.PersonID, day, in.Fingerprint, b.ConfigHash, b.EngineVersion).Scan(&runID); err != nil {
				return fmt.Errorf("replay lookup: %w", err)
			}
			run.RunID = runID
			return repository.ErrDuplicateRun
		}
		run.RunID = runID

		// supersede previous current scores, then insert the new revision
		for _, sc := range b.Scores {
			if _, err := tx.Exec(ctx, `
				UPDATE wellness_daily_score SET is_current = false
				WHERE person_id = $1 AND logical_day = $2 AND formula_key = $3 AND is_current`,
				sc.PersonID, sc.LogicalDay, sc.FormulaKey); err != nil {
				return fmt.Errorf("supersede score %s: %w", sc.FormulaKey, err)
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO wellness_daily_score
					(run_id, person_id, logical_day, formula_key, formula_version,
					 config_hash, score, explanation, is_current)
				VALUES ($1,$2,$3,$4,$5,$6,$7,$8,true)`,
				run.RunID, sc.PersonID, sc.LogicalDay, sc.FormulaKey, sc.FormulaVersion,
				sc.ConfigHash, sc.Score, sc.Explanation); err != nil {
				return fmt.Errorf("insert score %s: %w", sc.FormulaKey, err)
			}
		}

		// goal changes: supersede current, append history
		for _, g := range b.GoalChanges {
			if _, err := tx.Exec(ctx, `
				UPDATE wellness_goal_state SET superseded_at = now()
				WHERE person_id = $1 AND goal_key = $2 AND superseded_at IS NULL`,
				g.PersonID, g.GoalKey); err != nil {
				return fmt.Errorf("supersede goal %s: %w", g.GoalKey, err)
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO wellness_goal_state
					(person_id, goal_key, value, bed_time_minutes, reason, source,
					 formula_key, config_hash, run_id, applied_at)
				VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
				g.PersonID, g.GoalKey, g.Value, g.BedTimeMinutes, g.Reason, g.Source,
				g.FormulaKey, g.ConfigHash, run.RunID, g.AppliedAt); err != nil {
				return fmt.Errorf("insert goal %s: %w", g.GoalKey, err)
			}
		}

		// baseline snapshot (idempotent per run)
		if b.Baseline != nil {
			if _, err := tx.Exec(ctx, `
				INSERT INTO wellness_baseline_snapshot (person_id, logical_day, metrics, run_id)
				VALUES ($1,$2,$3,$4)
				ON CONFLICT (person_id, logical_day, run_id) DO NOTHING`,
				b.Baseline.PersonID, b.Baseline.LogicalDay, b.Baseline.Metrics, run.RunID); err != nil {
				return fmt.Errorf("insert baseline: %w", err)
			}
		}
		return nil
	})
	if errors.Is(err, repository.ErrDuplicateRun) {
		return run, repository.ErrDuplicateRun
	}
	if err != nil {
		return nil, fmt.Errorf("persist bundle: %w", err)
	}
	return run, nil
}

// ── queries (STAGE 14 §11) ─────────────────────────────────────────────────

func (s *Store) CurrentScore(ctx context.Context, personID string, day time.Time, formulaKey string) (*repository.Score, error) {
	dayUTC := time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, time.UTC)
	var sc repository.Score
	err := s.pool.QueryRow(ctx, `
		SELECT run_id, person_id, logical_day, formula_key, formula_version,
		       config_hash, score, explanation, is_current
		FROM wellness_daily_score
		WHERE person_id = $1 AND logical_day = $2 AND formula_key = $3 AND is_current`,
		personID, dayUTC, formulaKey).Scan(&sc.RunID, &sc.PersonID, &sc.LogicalDay,
		&sc.FormulaKey, &sc.FormulaVersion, &sc.ConfigHash, &sc.Score, &sc.Explanation, &sc.IsCurrent)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &sc, nil
}

func (s *Store) ScoreHistory(ctx context.Context, personID string, day time.Time, formulaKey string) ([]repository.Score, error) {
	dayUTC := time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, time.UTC)
	rows, err := s.pool.Query(ctx, `
		SELECT run_id, person_id, logical_day, formula_key, formula_version,
		       config_hash, score, explanation, is_current
		FROM wellness_daily_score
		WHERE person_id = $1 AND logical_day = $2 AND formula_key = $3
		ORDER BY run_id DESC`, personID, dayUTC, formulaKey)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []repository.Score
	for rows.Next() {
		var sc repository.Score
		if err := rows.Scan(&sc.RunID, &sc.PersonID, &sc.LogicalDay, &sc.FormulaKey,
			&sc.FormulaVersion, &sc.ConfigHash, &sc.Score, &sc.Explanation, &sc.IsCurrent); err != nil {
			return nil, err
		}
		out = append(out, sc)
	}
	return out, rows.Err()
}

func (s *Store) RunRevisions(ctx context.Context, personID string, day time.Time) ([]repository.Run, error) {
	dayUTC := time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, time.UTC)
	rows, err := s.pool.Query(ctx, `
		SELECT run_id, person_id, logical_day, timezone, input_fingerprint, config_hash,
		       engine_version, formula_versions, quality, calculated_at, replaces_run_id
		FROM wellness_calculation_run
		WHERE person_id = $1 AND logical_day = $2
		ORDER BY run_id DESC`, personID, dayUTC)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []repository.Run
	for rows.Next() {
		var r repository.Run
		var fv []byte
		if err := rows.Scan(&r.RunID, &r.PersonID, &r.LogicalDay, &r.Timezone,
			&r.InputFingerprint, &r.ConfigHash, &r.EngineVersion, &fv, &r.QualityJSON,
			&r.CalculatedAt, &r.ReplacesRunID); err != nil {
			return nil, err
		}
		_ = json.Unmarshal(fv, &r.FormulaVersions)
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) CurrentGoal(ctx context.Context, personID string, goalKey string) (*repository.Goal, error) {
	var g repository.Goal
	err := s.pool.QueryRow(ctx, `
		SELECT person_id, goal_key, value, bed_time_minutes, reason, source,
		       formula_key, config_hash, run_id, applied_at
		FROM wellness_goal_state
		WHERE person_id = $1 AND goal_key = $2 AND superseded_at IS NULL`,
		personID, goalKey).Scan(&g.PersonID, &g.GoalKey, &g.Value, &g.BedTimeMinutes,
		&g.Reason, &g.Source, &g.FormulaKey, &g.ConfigHash, &g.RunID, &g.AppliedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &g, nil
}

func (s *Store) GoalHistory(ctx context.Context, personID string, goalKey string) ([]repository.Goal, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT person_id, goal_key, value, bed_time_minutes, reason, source,
		       formula_key, config_hash, run_id, applied_at
		FROM wellness_goal_state
		WHERE person_id = $1 AND goal_key = $2
		ORDER BY applied_at DESC`, personID, goalKey)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []repository.Goal
	for rows.Next() {
		var g repository.Goal
		if err := rows.Scan(&g.PersonID, &g.GoalKey, &g.Value, &g.BedTimeMinutes,
			&g.Reason, &g.Source, &g.FormulaKey, &g.ConfigHash, &g.RunID, &g.AppliedAt); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

func (s *Store) CurrentBaseline(ctx context.Context, personID string) (*repository.BaselineSnapshot, error) {
	var b repository.BaselineSnapshot
	err := s.pool.QueryRow(ctx, `
		SELECT person_id, logical_day, metrics, run_id
		FROM wellness_baseline_snapshot
		WHERE person_id = $1
		ORDER BY logical_day DESC, run_id DESC
		LIMIT 1`, personID).Scan(&b.PersonID, &b.LogicalDay, &b.Metrics, &b.RunID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &b, nil
}

// ActiveVersion implements repository.RegistryStore.
func (s *Store) ActiveVersion(ctx context.Context, key versioning.Key) (versioning.FormulaVersion, error) {
	var v versioning.FormulaVersion
	var status string
	var validFrom, validTo *time.Time
	err := s.pool.QueryRow(ctx, `
		SELECT formula_key, version, status, name, description, valid_from, valid_to
		FROM wellness_formula_version
		WHERE formula_key = $1 AND status = 'ACTIVE'
		ORDER BY version DESC LIMIT 1`, string(key)).Scan(&v.Key, &v.Version, &status,
		&v.Name, &v.Description, &validFrom, &validTo)
	if errors.Is(err, pgx.ErrNoRows) {
		return versioning.FormulaVersion{}, ErrInvalidFormulaVersion{Key: string(key)}
	}
	if err != nil {
		return versioning.FormulaVersion{}, err
	}
	switch status {
	case "DRAFT":
		v.Status = versioning.StatusDraft
	case "ACTIVE":
		v.Status = versioning.StatusActive
	case "RETIRED":
		v.Status = versioning.StatusRetired
	}
	if validFrom != nil {
		v.EffectiveFrom = *validFrom
	}
	return v, nil
}

// SeedFormulaVersions registers the parity v1 formulas (idempotent).
func (s *Store) SeedFormulaVersions(ctx context.Context, params []byte) error {
	reg := versioning.DefaultRegistry()
	for _, key := range []versioning.Key{versioning.KeySleep, versioning.KeyStress,
		versioning.KeyReadiness, versioning.KeyActivity, versioning.KeyGoalSteps, versioning.KeyGoalSleep} {
		v := reg.Active(key)
		if _, err := s.pool.Exec(ctx, `
			INSERT INTO wellness_formula_version
				(formula_key, version, status, name, description, parameters)
			VALUES ($1,$2,'ACTIVE',$3,$4,$5)
			ON CONFLICT (formula_key, version) DO NOTHING`,
			string(key), v.Version, v.Name, v.Description, params); err != nil {
			return fmt.Errorf("seed formula %s: %w", key, err)
		}
	}
	return nil
}

func jsonMap(m map[string]int) []byte {
	if m == nil {
		return []byte("{}")
	}
	b, _ := json.Marshal(m)
	return b
}

func nullableJSON(b []byte) any {
	if len(b) == 0 {
		return nil
	}
	return b
}
