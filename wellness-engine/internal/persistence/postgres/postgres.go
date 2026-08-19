// Postgres adapters for the wellness persistence layer (STAGE 15).
//
// Dependency direction: persistence → engine/domain. The pure engine NEVER
// imports pgx or this package. Schema: internal/persistence/migrations
// (embedded; applied by Migrate). Design: docs/wellness-persistence-design.md.
package postgres

import (
	"context"
	"fmt"
	"sort"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/persistence"
)

// Migrate applies all pending embedded migrations inside individual
// transactions, tracked in schema_migrations. Idempotent.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	if _, err := pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version    text PRIMARY KEY,
			applied_at timestamptz NOT NULL DEFAULT now()
		)`); err != nil {
		return fmt.Errorf("ensure schema_migrations: %w", err)
	}
	entries, err := persistence.MigrationsFS.ReadDir("migrations")
	if err != nil {
		return fmt.Errorf("list migrations: %w", err)
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && len(e.Name()) > 7 && e.Name()[len(e.Name())-7:] == ".up.sql" {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	for _, name := range names {
		var applied bool
		if err := pool.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)`, name,
		).Scan(&applied); err != nil {
			return err
		}
		if applied {
			continue
		}
		sqlBytes, err := persistence.MigrationsFS.ReadFile("migrations/" + name)
		if err != nil {
			return err
		}
		if err := withTx(ctx, pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, string(sqlBytes)); err != nil {
				return fmt.Errorf("apply %s: %w", name, err)
			}
			if _, err := tx.Exec(ctx,
				`INSERT INTO schema_migrations (version) VALUES ($1)`, name); err != nil {
				return err
			}
			return nil
		}); err != nil {
			return err
		}
	}
	return nil
}

// withTx runs fn inside one transaction, rolling back on error.
func withTx(ctx context.Context, pool *pgxpool.Pool, fn func(tx pgx.Tx) error) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback(ctx)
		return err
	}
	return tx.Commit(ctx)
}

// ErrInvalidFormulaVersion is raised when a bundle references a formula
// version that is not registered ACTIVE in wellness_formula_version.
type ErrInvalidFormulaVersion struct {
	Key     string
	Version int
}

func (e ErrInvalidFormulaVersion) Error() string {
	return fmt.Sprintf("formula %s version %d not registered", e.Key, e.Version)
}
