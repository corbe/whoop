// DartRunner — invokes the REAL Dart oracle runner (test/diff_runner_test.dart
// via flutter test) and parses its results (STAGE 18.3). No formula logic
// here; the Dart side executes the actual production service classes.
package differential

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"
)

// DartResults maps fixture_id → normalized Result (as emitted by the Dart
// runner: ints/floats/bools/nulls; parse leniently into Result).
type DartResults map[string]map[string]any

// DartRunner invokes the oracle and returns the raw results map.
func DartRunner(fixturesDir, outDir string) (DartResults, time.Duration, error) {
	start := time.Now()
	root, err := repoRoot()
	if err != nil {
		return nil, 0, err
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return nil, 0, err
	}
	cmd := exec.Command("flutter", "test", "test/diff_runner_test.dart", "-j", "1")
	cmd.Dir = root
	cmd.Env = append(os.Environ(),
		"DIFF_FIXTURES_DIR="+fixturesDir,
		"DIFF_OUT_DIR="+outDir,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, 0, fmt.Errorf("dart runner failed: %v\n%s", err, tail(out, 1500))
	}
	raw, err := os.ReadFile(filepath.Join(outDir, "dart-results.json"))
	if err != nil {
		return nil, 0, fmt.Errorf("read dart results: %w\n%s", err, tail(out, 1500))
	}
	var results DartResults
	if err := json.Unmarshal(raw, &results); err != nil {
		return nil, 0, fmt.Errorf("parse dart results: %w", err)
	}
	return results, time.Since(start), nil
}

// repoRoot resolves the repository root (parent of wellness-engine/).
func repoRoot() (string, error) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		return "", fmt.Errorf("cannot resolve repo root")
	}
	// internal/differential → internal → wellness-engine → repo root
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", "..")), nil
}

func tail(b []byte, n int) string {
	s := string(b)
	if len(s) > n {
		s = s[len(s)-n:]
	}
	return s
}
