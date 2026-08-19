// wellness-api — the RITMA wellness REST API (STAGE 17).
//
// Run locally (no deploy): DATABASE_URL + INTERNAL_TOKEN + PORT env.
// Migrates and seeds the formula registry on startup. The auth subject
// resolver is the header-based test resolver — production wiring (Cognito)
// is a later stage; the resolver boundary fails closed.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/application"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/persistence/postgres"
	httpapi "github.com/noana-org/noana-wellness-app/wellness-engine/internal/transport/httpapi"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		slog.Error("DATABASE_URL is required")
		os.Exit(1)
	}
	internalToken := os.Getenv("INTERNAL_TOKEN")
	addr := os.Getenv("PORT")
	if addr == "" {
		addr = "8080"
	}
	addr = ":" + addr

	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		slog.Error("connect db", "err", err)
		os.Exit(1)
	}
	defer pool.Close()

	if err := postgres.Migrate(ctx, pool); err != nil {
		slog.Error("migrate", "err", err)
		os.Exit(1)
	}
	store := postgres.NewStore(pool)
	svc := application.New(store, nil, engine.DefaultConfigs())
	srv := httpapi.New(svc, httpapi.HeaderSubjectResolver{}, httpapi.InternalAuth{Token: internalToken},
		func() error {
			c, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			return pool.Ping(c)
		})

	httpServer := &http.Server{Addr: addr, Handler: srv.Handler()}
	go func() {
		slog.Info("wellness-api listening", "addr", addr)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("serve", "err", err)
			stop()
		}
	}()
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpServer.Shutdown(shutdownCtx)
}
