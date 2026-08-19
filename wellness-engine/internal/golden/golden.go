// Package golden loads the machine-executed compatibility oracle
// (docs/golden/oracle.json) for Go golden tests.
//
// The oracle was produced by running the REAL Dart algorithm classes
// (test/golden_oracle_test.dart, `flutter test` → 5/5) — see
// docs/wellness-golden-dataset.md. Tolerance policy: integer scores EXACT;
// doubles relative 1e-9 (float artifacts like pctLight 57.99999999999999
// are reproduced, not "fixed").
package golden

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

// Load reads the oracle JSON. It resolves the repo-relative path from the
// package's source location so tests work from any working directory.
func Load() (map[string]any, error) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		return nil, fmt.Errorf("cannot resolve source path")
	}
	// internal/golden/golden.go → repo root (3 levels up)
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	p := filepath.Join(root, "docs", "golden", "oracle.json")
	raw, err := os.ReadFile(p)
	if err != nil {
		return nil, fmt.Errorf("read oracle %s: %w", p, err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("parse oracle %s: %w", p, err)
	}
	return m, nil
}
