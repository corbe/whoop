// Test DB harness: real Postgres for integration tests (STAGE 17.15/17.16).
// TEST_DATABASE_URL wins; otherwise a postgres:16-alpine container via
// Docker. Tests SKIP (not fail) when neither is available.
package dbtest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/persistence/postgres"
)

var (
	mu      sync.Mutex
	pool    *pgxpool.Pool
	clean   func()
	started bool
)

// Pool returns the shared test database (starting it on first use).
// t.Skip when no database is reachable.
func Pool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	mu.Lock()
	defer mu.Unlock()
	if started {
		return pool
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		u, id, err := startContainer(ctx)
		if err != nil {
			started = true
			t.Skipf("postgres integration tests skipped: %v", err)
		}
		url = u
		clean = func() { _ = exec.Command("docker", "rm", "-f", id).Run() }
	}
	p, err := pgxpool.New(ctx, url)
	if err != nil {
		started = true
		t.Skipf("postgres connect: %v", err)
	}
	for i := 0; i < 30; i++ {
		if p.Ping(ctx) == nil {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if err := p.Ping(ctx); err != nil {
		started = true
		t.Skipf("postgres not ready: %v", err)
	}
	pool = p
	started = true
	return pool
}

// Setup applies migrations, truncates and seeds formula versions. Call per
// test for a hermetic database.
func Setup(t *testing.T) *pgxpool.Pool {
	t.Helper()
	p := Pool(t)
	ctx := context.Background()
	if err := postgres.Migrate(ctx, p); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if _, err := p.Exec(ctx, `
		TRUNCATE wellness_calculation_run, wellness_daily_score,
		         wellness_goal_state, wellness_baseline_snapshot, wellness_formula_version
		RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	params, _ := json.Marshal(engine.DefaultConfigs())
	if err := postgres.NewStore(p).SeedFormulaVersions(ctx, params); err != nil {
		t.Fatalf("seed formulas: %v", err)
	}
	return p
}

func startContainer(ctx context.Context) (string, string, error) {
	if _, err := exec.LookPath("docker"); err != nil {
		return "", "", errors.New("docker not found")
	}
	if err := exec.CommandContext(ctx, "docker", "info").Run(); err != nil {
		return "", "", errors.New("docker daemon unavailable")
	}
	port, err := freePort()
	if err != nil {
		return "", "", err
	}
	id, err := exec.CommandContext(ctx, "docker", "run", "-d", "--name", fmt.Sprintf("ritma-wt-%d", time.Now().UnixNano()),
		"-p", fmt.Sprintf("127.0.0.1:%d:5432", port),
		"-e", "POSTGRES_PASSWORD=test", "-e", "POSTGRES_DB=wellness_test",
		"postgres:16-alpine").Output()
	if err != nil {
		return "", "", fmt.Errorf("docker run: %w", err)
	}
	url := fmt.Sprintf("postgres://postgres:test@127.0.0.1:%d/wellness_test?sslmode=disable", port)
	return url, strings.TrimSpace(string(id)), nil
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}
