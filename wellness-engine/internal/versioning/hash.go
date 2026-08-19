// Deterministic config hashing (docs/formula-versioning.md §config-hash).
//
// Produces "sha256:<hex>" over the SEMANTIC configuration values only.
// Guarantees:
//   - same semantic config → same hash (no maps, no iteration order, no
//     memory addresses, no timestamps)
//   - different relevant config → different hash (every typed field
//     participates)
//   - runtime metadata (engine version, calculated_at) is structurally
//     excluded: it is not part of the inputs to HashConfig.
//
// Serialization rules:
//   - struct fields are emitted in DECLARATION ORDER (reflect order is
//     deterministic for a fixed type)
//   - floats: strconv.FormatFloat(v, 'g', -1, 64) — deterministic for the
//     same IEEE754 bits (0.10 and 0.1 hash identically)
//   - ints: base-10; bools: "t"/"f"; strings: strconv.Quote
//   - slices: "[" + canonical(each) joined by "," + "]"; ORDER MATTERS
//     (instant windows are ordered semantics)
//   - pointers: "nil" or "*" + canonical
package versioning

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"reflect"
	"strconv"
	"strings"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/config"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/goals"
)

var timeType = reflect.TypeOf(time.Time{})

// ConfigSet is the full effective configuration for one calculation.
type ConfigSet struct {
	Sleep     config.Sleep
	Stress    config.Stress
	Readiness config.Readiness
	Activity  config.Activity
	Baseline  config.Baseline
	Goals     goals.Config
}

// HashConfig hashes the full configuration set. The goals config is included
// because F-08/F-09 thresholds change goal outputs (and therefore,
// transitively, the goals the scores consume).
func HashConfig(c ConfigSet) string {
	var b strings.Builder
	b.WriteString("sleep=")
	b.WriteString(canonical(reflect.ValueOf(c.Sleep)))
	b.WriteString("|stress=")
	b.WriteString(canonical(reflect.ValueOf(c.Stress)))
	b.WriteString("|readiness=")
	b.WriteString(canonical(reflect.ValueOf(c.Readiness)))
	b.WriteString("|activity=")
	b.WriteString(canonical(reflect.ValueOf(c.Activity)))
	b.WriteString("|baseline=")
	b.WriteString(canonical(reflect.ValueOf(c.Baseline)))
	b.WriteString("|goals=")
	b.WriteString(canonical(reflect.ValueOf(c.Goals)))
	sum := sha256.Sum256([]byte(b.String()))
	return "sha256:" + hex.EncodeToString(sum[:])
}

// CanonicalString serializes any value deterministically (see package doc /
// HashConfig). It is the shared primitive for the config hash AND the input
// fingerprint (engine.Input.Fingerprint). time.Time values serialize by
// UnixNano (instant only — Location is deliberately ignored).
func CanonicalString(v any) (string, error) {
	return canonical(reflect.ValueOf(v)), nil
}

// canonical serializes any struct/int/float/bool/string/slice/pointer value
// deterministically (see package doc).
func canonical(v reflect.Value) string {
	if v.Type() == timeType {
		return "t=" + strconv.FormatInt(v.Interface().(time.Time).UnixNano(), 10)
	}
	switch v.Kind() {
	case reflect.Struct:
		parts := make([]string, 0, v.NumField())
		t := v.Type()
		for i := 0; i < v.NumField(); i++ {
			parts = append(parts, t.Field(i).Name+"="+canonical(v.Field(i)))
		}
		return "{" + strings.Join(parts, ",") + "}"
	case reflect.Float32, reflect.Float64:
		return strconv.FormatFloat(v.Float(), 'g', -1, 64)
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return strconv.FormatInt(v.Int(), 10)
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return strconv.FormatUint(v.Uint(), 10)
	case reflect.Bool:
		if v.Bool() {
			return "t"
		}
		return "f"
	case reflect.String:
		return strconv.Quote(v.String())
	case reflect.Slice, reflect.Array:
		parts := make([]string, v.Len())
		for i := 0; i < v.Len(); i++ {
			parts[i] = canonical(v.Index(i))
		}
		return "[" + strings.Join(parts, ",") + "]"
	case reflect.Ptr, reflect.Interface:
		if v.IsNil() {
			return "nil"
		}
		return "*" + canonical(v.Elem())
	default:
		// Unsupported kinds would break determinism guarantees — refuse loudly.
		panic(fmt.Sprintf("config hash: unsupported kind %s (value %v)", v.Kind(), v))
	}
}
