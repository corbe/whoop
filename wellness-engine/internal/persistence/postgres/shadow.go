// Shadow comparison persistence (STAGE 19B, PART B). The Go shadow writes
// ONLY here — official wellness tables are never touched by the shadow path.
package postgres

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// ShadowComparison is one person-day comparison record.
type ShadowComparison struct {
	ID               int64
	PersonHash       string
	LogicalDay       time.Time
	InputFingerprint string
	Official         [4]*int // sleep, stress, readiness, activity (nil = unavailable)
	Shadow           [4]*int
	Delta            [4]*int
	MatchClass       string // EXACT | EXPECTED_ONLY | MISMATCHED | INPUT_INCOMPLETE
	FormulaVersion   string
	ConfigHash       string
	EngineVersion    string
	GoRunID          *int64
	OfficialRef      string
	FailureCode      string
	ComparedAt       time.Time
}

// ShadowStore persists shadow comparisons in the isolated shadow table.
type ShadowStore struct {
	pool *pgxpool.Pool
}

// NewShadowStore builds the shadow store on the given pool.
func NewShadowStore(pool *pgxpool.Pool) *ShadowStore {
	return &ShadowStore{pool: pool}
}

// InsertShadowComparison upserts one comparison (idempotent by
// person_hash + logical_day + input_fingerprint).
func (s *ShadowStore) InsertShadowComparison(ctx context.Context, c ShadowComparison) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO wellness_shadow_comparison (
			person_hash, logical_day, input_fingerprint,
			official_sleep, official_stress, official_readiness, official_activity,
			shadow_sleep, shadow_stress, shadow_readiness, shadow_activity,
			delta_sleep, delta_stress, delta_readiness, delta_activity,
			match_class, formula_version, config_hash, engine_version,
			go_run_id, official_reference, failure_code
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22)
		ON CONFLICT (person_hash, logical_day, input_fingerprint) DO UPDATE SET
			match_class = EXCLUDED.match_class,
			failure_code = EXCLUDED.failure_code,
			compared_at = now()`,
		c.PersonHash, c.LogicalDay, c.InputFingerprint,
		ptrOrNil(c.Official[0]), ptrOrNil(c.Official[1]), ptrOrNil(c.Official[2]), ptrOrNil(c.Official[3]),
		ptrOrNil(c.Shadow[0]), ptrOrNil(c.Shadow[1]), ptrOrNil(c.Shadow[2]), ptrOrNil(c.Shadow[3]),
		ptrOrNil(c.Delta[0]), ptrOrNil(c.Delta[1]), ptrOrNil(c.Delta[2]), ptrOrNil(c.Delta[3]),
		c.MatchClass, c.FormulaVersion, c.ConfigHash, c.EngineVersion,
		c.GoRunID, c.OfficialRef, c.FailureCode)
	return err
}

// ShadowSummary counts the comparison outcomes (operational metrics).
type ShadowSummary struct {
	Total            int
	Matches          int
	Mismatches       int
	IncompleteInputs int
	Failures         int
}

// ShadowSummary returns aggregate counts for the shadow cohort.
func (s *ShadowStore) ShadowSummary(ctx context.Context, from, to time.Time) (ShadowSummary, error) {
	var out ShadowSummary
	err := s.pool.QueryRow(ctx, `
		SELECT count(*),
			count(*) FILTER (WHERE match_class = 'EXACT' OR match_class = 'EXPECTED_ONLY'),
			count(*) FILTER (WHERE match_class = 'MISMATCHED'),
			count(*) FILTER (WHERE match_class = 'INPUT_INCOMPLETE'),
			count(*) FILTER (WHERE failure_code IS NOT NULL)
		FROM wellness_shadow_comparison
		WHERE logical_day BETWEEN $1 AND $2`, from, to).
		Scan(&out.Total, &out.Matches, &out.Mismatches, &out.IncompleteInputs, &out.Failures)
	return out, err
}

func ptrOrNil(p *int) any {
	if p == nil {
		return nil
	}
	return *p
}
