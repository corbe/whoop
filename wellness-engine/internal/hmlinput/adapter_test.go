// HML input provider tests: client parsing of the real envelope shape,
// bounded retry, and fixture construction (segments, baselines, incomplete
// flags).
package hmlinput

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func envelope(slug string, pairs [][2]float64) []byte {
	raw, _ := json.Marshal([]any{
		200,
		map[string]any{
			"parameters": []any{
				map[string]any{"data": map[string]any{slug: pairs}},
			},
		},
	})
	return raw
}

func TestClientFetchRange(t *testing.T) {
	day := time.Date(2026, 8, 10, 0, 0, 0, 0, time.Local)
	base := day.AddDate(0, 0, -1).UnixMilli()
	mux := http.NewServeMux()
	mux.HandleFunc("/person/u1/batimento-cardiaco/timeseries/json/", func(w http.ResponseWriter, r *http.Request) {
		w.Write(envelope("batimento-cardiaco", [][2]float64{{float64(base + 1000), 70}, {float64(base + 2000), 75}}))
	})
	mux.HandleFunc("/person/u1/variabilidade-de-fc/timeseries/json/", func(w http.ResponseWriter, r *http.Request) {
		w.Write(envelope("variabilidade-de-fc", [][2]float64{{float64(base + 1000), 40.5}}))
	})
	mux.HandleFunc("/person/u1/oxigenacao/timeseries/json/", func(w http.ResponseWriter, r *http.Request) {
		w.Write(envelope("oxigenacao", [][2]float64{{float64(base + 1000), 96.0}}))
	})
	mux.HandleFunc("/person/u1/passos/timeseries/json/", func(w http.ResponseWriter, r *http.Request) {
		w.Write(envelope("passos", [][2]float64{{float64(day.UnixMilli() + 1000), 4200}}))
	})
	mux.HandleFunc("/person/u1/hipnograma/timeseries/json/", func(w http.ResponseWriter, r *http.Request) {
		// transitions [t, stage]
		w.Write(envelope("hipnograma", [][2]float64{
			{float64(day.AddDate(0, 0, -1).UnixMilli() + 23*3600*1000 + 26*60*1000), -3},
			{float64(day.UnixMilli() + 4*60*1000), -1},
			{float64(day.UnixMilli() + 42*60*1000), -4},
			{float64(day.UnixMilli() + 2*3600*1000 + 18*60*1000), -3},
			{float64(day.UnixMilli() + 7*3600*1000 + 26*60*1000), 0},
		}))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	c := NewClient(srv.URL, "tok")
	b, err := c.FetchRange(context.Background(), "u1", day.AddDate(0, 0, -30), day)
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if len(b.HR) != 2 || len(b.HRV) != 1 || len(b.SpO2) != 1 || len(b.Steps) != 1 || len(b.Hipnograma) != 5 {
		t.Fatalf("bundle sizes: hr=%d hrv=%d spo2=%d steps=%d hip=%d", len(b.HR), len(b.HRV), len(b.SpO2), len(b.Steps), len(b.Hipnograma))
	}
	if b.HR[0].Value != 70 || b.Hipnograma[0].Stage != -3 {
		t.Fatalf("parse mismatch: %+v %+v", b.HR[0], b.Hipnograma[0])
	}
}

func TestClientRetryOn5xx(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			w.WriteHeader(502)
			return
		}
		w.Write(envelope("passos", [][2]float64{{1, 1}}))
	}))
	defer srv.Close()
	c := NewClient(srv.URL, "")
	pts, err := c.fetchTimeseries(context.Background(), "u", "passos", time.Now().Add(-time.Hour), time.Now())
	if err != nil || len(pts) != 1 || calls != 2 {
		t.Fatalf("retry: err=%v calls=%d pts=%d", err, calls, len(pts))
	}
}

func TestClientRejectsNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(404)
	}))
	defer srv.Close()
	c := NewClient(srv.URL, "")
	if _, err := c.fetchTimeseries(context.Background(), "u", "passos", time.Now().Add(-time.Hour), time.Now()); err == nil {
		t.Fatal("expected error on 404")
	}
}

// TestBuildFixtureIncomplete asserts that missing calories/session and
// missing sidecar inputs mark the case INPUT_INCOMPLETE without fabrication.
func TestBuildFixtureIncomplete(t *testing.T) {
	day := time.Date(2026, 8, 10, 0, 0, 0, 0, time.Local)
	loc := time.Local
	b := &Bundle{
		Steps: []TimeseriesPoint{{TimestampMs: day.UnixMilli() + 3600*1000, Value: 5000}},
		Hipnograma: []HipnogramaItem{
			{IsTransition: true, TransitionT: day.AddDate(0, 0, -1).UnixMilli() + 22*3600*1000, Stage: -3},
			{IsTransition: true, TransitionT: day.UnixMilli() + 6*3600*1000, Stage: 0},
		},
	}
	f, incomplete, err := BuildFixture(b, nil, day, loc, "hash1")
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if len(incomplete) < 2 {
		t.Fatalf("expected incomplete flags (calories + demographics), got %v", incomplete)
	}
	if f.FixtureID == "" || f.PersonID != "hash1" {
		t.Fatalf("fixture identity: %+v", f)
	}
	// With a full sidecar, calories flag remains (backend value-only) but
	// session kcal presence clears it.
	side := &Sidecar{GoalStepsCurrent: 7000, Gender: "M", BirthDate: "1990-01-01", SessionKcal: 120}
	_, incomplete2, err := BuildFixture(b, side, day, loc, "hash1")
	if err != nil {
		t.Fatalf("build2: %v", err)
	}
	if len(incomplete2) != 0 {
		t.Fatalf("full sidecar should clear incompleteness, got %v", incomplete2)
	}
	_ = fmt.Sprint
}
