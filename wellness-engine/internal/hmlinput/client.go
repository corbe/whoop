// HML backend input provider (STAGE 19B, PART A).
//
// Fetches the same backend timeseries the official app consumes
// (/person/{uuid}/{slug}/timeseries/json/ + /hipnograma/timeseries/json/)
// and converts them into the canonical differential Fixture, so the Go
// shadow receives the SAME normalized inputs as the Dart official path.
//
// Response contract (verified against the app's apiCall/extractSeries):
//   HTTP 200 body = [status_code, {parameters: [{data: {<slug>: [[ts, value], ...]}}]}]
package hmlinput

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Client fetches person-scoped timeseries ranges from the backend API.
type Client struct {
	BaseURL string // e.g. https://api.hml.noana.link/v1
	Token   string // internal/service token (never logged)
	HTTP    *http.Client
}

// NewClient builds a client with sane timeouts and bounded retries.
func NewClient(baseURL, token string) *Client {
	return &Client{
		BaseURL: strings.TrimSuffix(baseURL, "/"),
		Token:   token,
		HTTP: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// TimeseriesPoint is one [timestamp_ms, value] sample.
type TimeseriesPoint struct {
	TimestampMs int64
	Value       float64
}

// HipnogramaItem is a raw hipnograma payload entry: either a [t, stage]
// transition or a {startTime,endTime,type} map (both shapes occur in the
// backend payload; the app handles both — mirrored here).
type HipnogramaItem struct {
	IsTransition bool
	TransitionT  int64
	Stage        int
	StartMs      int64
	EndMs        int64
}

// Bundle is one person's raw range fetch (no derivation, no PII — person is
// keyed by the caller-supplied pseudonym).
type Bundle struct {
	HR        []TimeseriesPoint
	HRV       []TimeseriesPoint
	SpO2      []TimeseriesPoint
	Steps     []TimeseriesPoint
	Hipnograma []HipnogramaItem
}

var errStatus = func(status int) error { return fmt.Errorf("hml backend status %d", status) }

// FetchRange pulls all metrics for [startAt, endAt] with batched range
// requests (one request per metric, not per sample). Bounded retry: 2
// attempts on transient errors (5xx, network), no retry storm.
func (c *Client) FetchRange(ctx context.Context, personUUID string, startAt, endAt time.Time) (*Bundle, error) {
	b := &Bundle{}
	slugs := []struct {
		slug string
		dst  *[]TimeseriesPoint
	}{
		{"batimento-cardiaco", &b.HR},
		{"variabilidade-de-fc", &b.HRV},
		{"oxigenacao", &b.SpO2},
		{"passos", &b.Steps},
	}
	for _, s := range slugs {
		pts, err := c.fetchTimeseries(ctx, personUUID, s.slug, startAt, endAt)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", s.slug, err)
		}
		*s.dst = pts
	}
	hip, err := c.fetchHipnograma(ctx, personUUID, startAt, endAt)
	if err != nil {
		return nil, fmt.Errorf("hipnograma: %w", err)
	}
	b.Hipnograma = hip
	return b, nil
}

func (c *Client) fetchTimeseries(ctx context.Context, personUUID, slug string, startAt, endAt time.Time) ([]TimeseriesPoint, error) {
	path := fmt.Sprintf("/person/%s/%s/timeseries/json/?start_at=%s&end_at=%s",
		url.PathEscape(personUUID), url.PathEscape(slug),
		url.QueryEscape(startAt.Format("2006-01-02T15:04:05")),
		url.QueryEscape(endAt.Format("2006-01-02T15:04:05")))
	raw, err := c.get(ctx, path)
	if err != nil {
		return nil, err
	}
	items, err := extractSeries(raw, slug)
	if err != nil {
		return nil, err
	}
	var out []TimeseriesPoint
	for _, it := range items {
		p, ok := it.([]any)
		if !ok || len(p) < 2 {
			continue
		}
		ts, ok1 := p[0].(float64)
		val, ok2 := p[1].(float64)
		if !ok1 || !ok2 {
			continue
		}
		out = append(out, TimeseriesPoint{TimestampMs: int64(ts), Value: val})
	}
	return out, nil
}

func (c *Client) fetchHipnograma(ctx context.Context, personUUID string, startAt, endAt time.Time) ([]HipnogramaItem, error) {
	path := fmt.Sprintf("/person/%s/hipnograma/timeseries/json/?start_at=%s&end_at=%s",
		url.PathEscape(personUUID),
		url.QueryEscape(startAt.Format("2006-01-02T15:04:05")),
		url.QueryEscape(endAt.Format("2006-01-02T15:04:05")))
	raw, err := c.get(ctx, path)
	if err != nil {
		return nil, err
	}
	items, err := extractSeries(raw, "hipnograma")
	if err != nil {
		return nil, err
	}
	var out []HipnogramaItem
	for _, it := range items {
		if arr, ok := it.([]any); ok && len(arr) >= 2 {
			if t, ok1 := arr[0].(float64); ok1 {
				if st, ok2 := arr[1].(float64); ok2 {
					out = append(out, HipnogramaItem{IsTransition: true, TransitionT: int64(t), Stage: int(st)})
					continue
				}
			}
		}
		if m, ok := it.(map[string]any); ok {
			start := numOf(m["startTime"], m["startTimeStamp"])
			end := numOf(m["endTime"], m["endTimeStamp"])
			stage := numOf(m["type"])
			if start > 0 && end > start {
				out = append(out, HipnogramaItem{StartMs: int64(start), EndMs: int64(end), Stage: int(stage)})
			}
		}
	}
	return out, nil
}

// get performs one GET with bounded retry (2 attempts on transient errors).
func (c *Client) get(ctx context.Context, path string) ([]byte, error) {
	urlStr := c.BaseURL + path
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(300 * time.Millisecond):
			}
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, urlStr, nil)
		if err != nil {
			return nil, err
		}
		if c.Token != "" {
			req.Header.Set("Authorization", "Bearer "+c.Token)
		}
		resp, err := c.HTTP.Do(req)
		if err != nil {
			lastErr = err
			continue // transient network error → retry
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
		resp.Body.Close()
		if resp.StatusCode >= 500 {
			lastErr = errStatus(resp.StatusCode)
			continue
		}
		if resp.StatusCode != 200 {
			return nil, errStatus(resp.StatusCode)
		}
		return body, nil
	}
	return nil, lastErr
}

// extractSeries mirrors the app's extractSeries: parameters[].data[slug].
func extractSeries(raw []byte, slug string) ([]any, error) {
	var envelope []json.RawMessage
	if err := json.Unmarshal(raw, &envelope); err != nil || len(envelope) < 2 {
		return nil, fmt.Errorf("invalid envelope (want [status, body]): %w", err)
	}
	var status int
	if err := json.Unmarshal(envelope[0], &status); err != nil {
		return nil, fmt.Errorf("invalid status: %w", err)
	}
	if status != 200 {
		return nil, errStatus(status)
	}
	var body struct {
		Parameters []struct {
			Data map[string]json.RawMessage `json:"data"`
		} `json:"parameters"`
	}
	if err := json.Unmarshal(envelope[1], &body); err != nil {
		return nil, fmt.Errorf("invalid body: %w", err)
	}
	for _, p := range body.Parameters {
		if rawList, ok := p.Data[slug]; ok {
			var list []any
			if err := json.Unmarshal(rawList, &list); err != nil {
				return nil, fmt.Errorf("invalid %s series: %w", slug, err)
			}
			return list, nil
		}
	}
	return nil, nil
}

func numOf(vals ...any) float64 {
	for _, v := range vals {
		if f, ok := v.(float64); ok {
			return f
		}
	}
	return 0
}
