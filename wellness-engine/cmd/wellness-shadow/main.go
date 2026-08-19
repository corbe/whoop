// wellness-shadow — Phase A historical replay runner (STAGE 19B, PART C).
//
// For each person/day in the cohort: fetch canonical inputs (HML backend or
// a local fixtures dir), run the Go shadow engine, resolve the OFFICIAL
// result from the cohort file, compare with the Stage 18 comparator
// semantics, and persist the comparison to the isolated shadow table.
//
// The official path is never modified. Failures are recorded and the batch
// continues; exit code is non-zero only on harness operational failure.
//
// Usage:
//
//	wellness-shadow --cohort-file cohort.json --from 2026-08-01 --to 2026-08-07 \
//	  --api-base-url https://api.hml.noana.link/v1 --api-token $TOKEN \
//	  --db-url "$DATABASE_URL" [--dry-run]
//
// Cohort file (operator-only, NEVER committed; person_uuid is the backend
// identifier, person_hash is the stored/compared pseudonym):
//
//	[{"person_hash": "ab12...", "person_uuid": "<backend uuid>",
//	  "sidecar": {...}, "official": {"2026-08-01": {"sleep": 90, "stress": 40,
//	  "readiness": 78, "activity": 78, "reference": "run-123"}}}]
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/differential"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/hmlinput"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/persistence/postgres"
)

type cohortEntry struct {
	PersonHash string                   `json:"person_hash"`
	PersonUUID string                   `json:"person_uuid"`
	Sidecar    *hmlinput.Sidecar        `json:"sidecar,omitempty"`
	Official   map[string]officialScores `json:"official"`
}

type officialScores struct {
	Sleep     int    `json:"sleep"`
	Stress    int    `json:"stress"`
	Readiness int    `json:"readiness"`
	Activity  int    `json:"activity"`
	Reference string `json:"reference,omitempty"`
}

type dayResult struct {
	entry      cohortEntry
	day        time.Time
	fixture    *differential.Fixture
	incomplete []string
	shadow     *differential.Result
	official   *officialScores
	matchClass string
	failure    string
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var (
		cohortFile  = flag.String("cohort-file", "", "cohort JSON (person_hash/person_uuid/sidecar/official)")
		from        = flag.String("from", "", "inclusive start day YYYY-MM-DD")
		to          = flag.String("to", "", "inclusive end day YYYY-MM-DD")
		apiBase     = flag.String("api-base-url", "", "HML backend base URL")
		apiToken    = flag.String("api-token", "", "HML backend service token (env WELLNESS_HML_TOKEN preferred)")
		fixturesDir = flag.String("fixtures-dir", "", "test mode: read canonical fixtures instead of fetching")
		dbURL       = flag.String("db-url", "", "shadow DB URL (env DATABASE_URL preferred)")
		dryRun      = flag.Bool("dry-run", false, "do not persist; print a summary only")
		timeout     = flag.Duration("timeout", 30*time.Second, "per-case timeout")
	)
	flag.Parse()

	if *cohortFile == "" || *from == "" || *to == "" {
		fatal("--cohort-file, --from and --to are required")
	}
	start, err := time.ParseInLocation("2006-01-02", *from, time.Local)
	if err != nil {
		fatal(err)
	}
	end, err := time.ParseInLocation("2006-01-02", *to, time.Local)
	if err != nil {
		fatal(err)
	}
	raw, err := os.ReadFile(*cohortFile)
	if err != nil {
		fatal(err)
	}
	var cohort []cohortEntry
	if err := json.Unmarshal(raw, &cohort); err != nil {
		fatal(fmt.Errorf("cohort file: %w", err))
	}
	if *apiToken == "" {
		*apiToken = os.Getenv("WELLNESS_HML_TOKEN")
	}
	if *dbURL == "" {
		*dbURL = os.Getenv("DATABASE_URL")
	}

	var store *postgres.ShadowStore
	if !*dryRun {
		if *dbURL == "" {
			fatal("--db-url or DATABASE_URL required unless --dry-run")
		}
		pool, err := pgxpool.New(ctx, *dbURL)
		if err != nil {
			fatal(err)
		}
		defer pool.Close()
		if err := postgres.Migrate(ctx, pool); err != nil {
			fatal(fmt.Errorf("migrate: %w", err))
		}
		store = postgres.NewShadowStore(pool)
	}

	client := hmlinput.NewClient(*apiBase, *apiToken)
	runner := differential.NewGoRunner(engine.DefaultConfigs())

	// Collect per-day results (bounded; replay is offline).
	var results []dayResult
	days := 0
	for d := start; !d.After(end); d = d.AddDate(0, 0, 1) {
		days++
		for _, entry := range cohort {
			cctx, cancel := context.WithTimeout(ctx, *timeout)
			res := dayResult{entry: entry, day: d}
			ofc, ok := entry.Official[d.Format("2006-01-02")]
			if !ok {
				cancel()
				continue // no official reference → nothing to compare
			}
			res.official = &ofc

			// 1. canonical inputs
			if *fixturesDir != "" {
				fp := filepath.Join(*fixturesDir, fmt.Sprintf("%s_%s.json", entry.PersonHash, d.Format("2006-01-02")))
				if rawF, err := os.ReadFile(fp); err == nil {
					var f differential.Fixture
					if err := json.Unmarshal(rawF, &f); err == nil {
						res.fixture = &f
					}
				}
				if res.fixture == nil {
					res.failure = "fixture_missing"
					res.matchClass = "FAILED"
					results = append(results, res)
					cancel()
					continue
				}
			} else {
				b, err := client.FetchRange(cctx, entry.PersonUUID, d.AddDate(0, 0, -30), d.AddDate(0, 0, 1))
				if err != nil {
					res.failure = "input_fetch:" + err.Error()
					res.matchClass = "FAILED"
					results = append(results, res)
					cancel()
					continue
				}
				f, incomplete, err := hmlinput.BuildFixture(b, entry.Sidecar, d, time.Local, entry.PersonHash)
				if err != nil {
					res.failure = "input_build:" + err.Error()
					res.matchClass = "FAILED"
					results = append(results, res)
					cancel()
					continue
				}
				res.fixture = f
				res.incomplete = incomplete
			}

			// 2. Go shadow calculation
			shadow, err := runner.Run(res.fixture)
			if err != nil {
				res.failure = "engine:" + err.Error()
				res.matchClass = "FAILED"
				results = append(results, res)
				cancel()
				continue
			}
			res.shadow = shadow

			// 3. compare (official scores vs shadow scores; the official
			// path does not export intermediates — ints compare EXACTLY).
			res.matchClass = classify(res)
			results = append(results, res)
			cancel()
		}
	}

	// 4/5. persist + summary
	var exact, mismatched, incompleteC, failed int
	for _, r := range results {
		switch r.matchClass {
		case "EXACT":
			exact++
		case "MISMATCHED":
			mismatched++
		case "INPUT_INCOMPLETE":
			incompleteC++
		default:
			failed++
		}
		if store != nil {
			ictx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			store.InsertShadowComparison(ictx, comparisonOf(r))
			cancel()
		}
	}
	fmt.Printf("shadow days=%d cases=%d exact=%d mismatched=%d input_incomplete=%d failed=%d\n",
		days, len(results), exact, mismatched, incompleteC, failed)
	if mismatched > 0 || failed > 0 {
		fmt.Fprintln(os.Stderr, "shadow: mismatched or failed cases recorded (see shadow table / logs)")
	}
}

func classify(r dayResult) string {
	if len(r.incomplete) > 0 {
		return "INPUT_INCOMPLETE"
	}
	o, s := r.official, r.shadow
	if o == nil || s == nil {
		return "FAILED"
	}
	if o.Sleep == s.Scores.Sleep && o.Stress == s.Scores.Stress &&
		o.Readiness == s.Scores.Readiness && o.Activity == s.Scores.Activity {
		return "EXACT"
	}
	return "MISMATCHED"
}

func comparisonOf(r dayResult) postgres.ShadowComparison {
	c := postgres.ShadowComparison{
		PersonHash: r.entry.PersonHash,
		LogicalDay: r.day,
		MatchClass: r.matchClass,
		FailureCode: func() string {
			if r.failure != "" {
				return r.failure
			}
			return ""
		}(),
		ComparedAt: time.Now().UTC(),
	}
	if r.fixture != nil {
		in := *r.fixture
		c.InputFingerprint = fingerprintOf(&in)
	}
	if r.official != nil {
		o := r.official
		c.Official = [4]*int{&o.Sleep, &o.Stress, &o.Readiness, &o.Activity}
		c.OfficialRef = o.Reference
	}
	if r.shadow != nil {
		s := r.shadow
		c.Shadow = [4]*int{&s.Scores.Sleep, &s.Scores.Stress, &s.Scores.Readiness, &s.Scores.Activity}
		ds, dt, dr, da := s.Scores.Sleep, s.Scores.Stress, s.Scores.Readiness, s.Scores.Activity
		if r.official != nil {
			ds -= r.official.Sleep
			dt -= r.official.Stress
			dr -= r.official.Readiness
			da -= r.official.Activity
		}
		c.Delta = [4]*int{&ds, &dt, &dr, &da}
	}
	return c
}

var fingerprintOf = func(f *differential.Fixture) string {
	raw, _ := json.Marshal(f)
	return fmt.Sprintf("sha256:%x", sha256Sum(raw))
}

func fatal(v any) {
	slog.Error("wellness-shadow", "err", fmt.Sprint(v))
	os.Exit(1)
}

func sha256Sum(b []byte) []byte {
	h := sha256.Sum256(b)
	return h[:]
}
