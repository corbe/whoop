// wellness-diff — Dart-Go differential harness CLI (STAGE 18).
//
// Usage:
//
//	wellness-diff --generate 200                       # write synthetic corpus to out-dir/fixtures
//	wellness-diff --fixtures-dir <dir>                 # Go-only comparison (no Dart)
//	wellness-diff --fixtures-dir <dir> --dart          # full Dart vs Go comparison
//
// Writes differential-report.json + differential-summary.txt. Exit 1 when
// the fail policy trips (unexplained mismatches > 0), unless --no-fail.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/differential"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
)

func main() {
	fixturesDir := flag.String("fixtures-dir", "", "canonical fixture directory")
	outDir := flag.String("out-dir", "wellness-diff-out", "output directory")
	generate := flag.Int("generate", 0, "generate N synthetic fixtures into out-dir/fixtures")
	seed := flag.Int64("seed", 42, "synthetic corpus seed")
	runDart := flag.Bool("dart", false, "execute the real Dart oracle runner")
	noFail := flag.Bool("no-fail", false, "exit 0 even with unexplained mismatches")
	flag.Parse()

	if *generate > 0 {
		dir := filepath.Join(*outDir, "fixtures")
		ids, err := differential.GenerateCorpus(dir, *generate, *seed)
		if err != nil {
			fatal(err)
		}
		fmt.Printf("generated %d fixtures in %s\n", len(ids), dir)
		if *fixturesDir == "" {
			*fixturesDir = dir
		}
	}
	if *fixturesDir == "" {
		fatal(fmt.Errorf("--fixtures-dir required (or --generate)"))
	}

	fixtures, err := differential.LoadFixtures(*fixturesDir)
	if err != nil {
		fatal(err)
	}
	if len(fixtures) == 0 {
		fatal(fmt.Errorf("no fixtures found in %s", *fixturesDir))
	}

	var timing differential.Timing
	runner := differential.NewGoRunner(engine.DefaultConfigs())
	goResults := map[string]*differential.Result{}
	goStart := time.Now()
	for _, f := range fixtures {
		r, err := runner.Run(f)
		if err != nil {
			fatal(fmt.Errorf("%s: %v", f.FixtureID, err))
		}
		goResults[f.FixtureID] = r
	}
	timing.GoMs = time.Since(goStart).Milliseconds()

	dartResults := differential.DartResults{}
	if *runDart {
		results, dur, err := differential.DartRunner(*fixturesDir, *outDir)
		if err != nil {
			fatal(err)
		}
		dartResults = results
		timing.DartMs = dur.Milliseconds()
		fmt.Printf("dart oracle: %d results in %s\n", len(results), dur.Round(time.Millisecond))
	} else {
		fmt.Println("dart oracle: skipped (--dart to run the real Dart implementation)")
	}

	compareStart := time.Now()
	var mismatches []differential.Mismatch
	for _, f := range fixtures {
		goRes := goResults[f.FixtureID]
		if *runDart {
			dartRaw, ok := dartResults[f.FixtureID]
			if !ok {
				fatal(fmt.Errorf("dart result missing for %s", f.FixtureID))
			}
			dartRes, err := parseDartResult(f.FixtureID, dartRaw)
			if err != nil {
				fatal(err)
			}
			mismatches = append(mismatches, differential.Compare(f.FixtureID, dartRes, goRes)...)
		}
	}
	timing.CompareMs = time.Since(compareStart).Milliseconds()

	rep := differential.BuildReport(len(fixtures), mismatches, timing)
	if err := differential.WriteReport(*outDir, rep); err != nil {
		fatal(err)
	}
	s := rep.Summary
	fmt.Printf("TOTAL CASES: %d\n", s.TotalCases)
	fmt.Printf("EXACT CASES: %d\n", s.ExactCases)
	fmt.Printf("EXPECTED-ONLY CASES: %d\n", s.ExpectedOnlyCases)
	fmt.Printf("MISMATCHED CASES: %d\n", s.MismatchedCases)
	fmt.Printf("TOTAL MISMATCH FIELDS: %d\n", s.TotalMismatchFields)
	fmt.Printf("EXPECTED FIELDS: %d\n", s.ExpectedDifferenceFields)
	fmt.Printf("UNEXPLAINED FIELDS: %d\n", s.UnexplainedMismatchFields)
	fmt.Printf("MAX SCORE DELTA: %d\n", s.MaxScoreDelta)
	for k, v := range s.MismatchByClass {
		fmt.Printf("  %s: %d\n", k, v)
	}
	if *runDart {
		fmt.Printf("timing: dart=%dms go=%dms compare=%dms\n", timing.DartMs, timing.GoMs, timing.CompareMs)
	}
	if s.MismatchedCases > 0 && !*noFail {
		fmt.Fprintln(os.Stderr, "FAIL: unexplained mismatches (fail policy)")
		os.Exit(1)
	}
}

func parseDartResult(id string, raw map[string]any) (*differential.Result, error) {
	b, err := json.Marshal(raw)
	if err != nil {
		return nil, err
	}
	var r differential.Result
	if err := json.Unmarshal(b, &r); err != nil {
		return nil, fmt.Errorf("%s: %w", id, err)
	}
	return &r, nil
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "wellness-diff:", err)
	os.Exit(1)
}
