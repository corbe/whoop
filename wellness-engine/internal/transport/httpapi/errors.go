// HTTP transport for the wellness API (STAGE 17).
//
// Layering: transport → application → engine/repository. Explicit DTOs only
// (no DB models, no engine structs leak). net/http ServeMux (Go 1.22+
// method+path patterns) — no framework.
package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
)

// ── auth boundary (STAGE 17.4 / 17.20) ─────────────────────────────────────

// SubjectResolver maps the authenticated context to a person ID. Real
// Cognito wiring is a later stage; every resolver MUST fail closed.
type SubjectResolver interface {
	PersonID(ctx context.Context) (string, error)
}

// HeaderSubjectResolver is the test/development resolver: reads the subject
// from a header. It fails closed (401) when the header is absent. NEVER use
// in production without a gateway that strips external headers.
type HeaderSubjectResolver struct {
	Header string // default X-Auth-Subject
}

func (h HeaderSubjectResolver) PersonID(ctx context.Context) (string, error) {
	name := h.Header
	if name == "" {
		name = "X-Auth-Subject"
	}
	r, ok := ctx.Value(ctxKeyRequest{}).(*http.Request)
	if !ok || r == nil {
		return "", errUnauthenticated
	}
	v := strings.TrimSpace(r.Header.Get(name))
	if v == "" {
		return "", errUnauthenticated
	}
	return v, nil
}

// InternalAuth validates requests to /internal/* routes. Test impl: shared
// token header. Fails closed.
type InternalAuth struct {
	Token string // header X-Internal-Token must equal this
}

func (a InternalAuth) Authorize(r *http.Request) bool {
	if a.Token == "" {
		return false
	}
	return r.Header.Get("X-Internal-Token") == a.Token
}

// ── error contract (STAGE 17.12) ───────────────────────────────────────────

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Details any    `json:"details,omitempty"`
}

type errorBody struct {
	Error apiError `json:"error"`
}

var (
	errUnauthenticated = errors.New("unauthenticated")
	errForbidden       = errors.New("forbidden")
	errNotFound        = errors.New("not found")
)

// mapError converts any error into a stable HTTP error payload. Never leaks
// pgx/SQL/stack details.
func mapError(w http.ResponseWriter, r *http.Request, err error) {
	status := http.StatusInternalServerError
	code := "INTERNAL_ERROR"
	msg := "internal error"
	var details any
	switch {
	case errors.Is(err, errUnauthenticated):
		status, code, msg = http.StatusUnauthorized, "UNAUTHENTICATED", "authentication required"
	case errors.Is(err, errForbidden):
		status, code, msg = http.StatusForbidden, "FORBIDDEN", "access denied"
	case errors.Is(err, errNotFound):
		status, code, msg = http.StatusNotFound, "NOT_FOUND", "not found"
	case isNoData(err):
		status, code, msg = http.StatusNotFound, "NO_DATA", err.Error()
	case isInvalidInput(err):
		status, code, msg = http.StatusBadRequest, "INVALID_INPUT", err.Error()
	case strings.Contains(err.Error(), "unexpected end of JSON") || isJSONErr(err):
		status, code, msg = http.StatusBadRequest, "INVALID_BODY", "malformed request body"
	}
	if status == http.StatusInternalServerError {
		slog.Error("api error", "method", r.Method, "path", r.URL.Path, "err", err)
	}
	writeJSON(w, status, errorBody{Error: apiError{Code: code, Message: msg, Details: details}})
}

func isNoData(err error) bool {
	var e *domain.ErrNoData
	return errors.As(err, &e)
}

func isInvalidInput(err error) bool {
	var e *domain.ErrInvalidInput
	return errors.As(err, &e)
}

func isJSONErr(err error) bool {
	var e *json.SyntaxError
	return errors.As(err, &e)
}

// ── helpers ────────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// parseDate validates strict YYYY-MM-DD; the logical day is never derived
// from the server's timezone (parsed in UTC).
func parseDate(s string) (time.Time, error) {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return time.Time{}, fmt.Errorf("date must be YYYY-MM-DD")
	}
	return t, nil
}

type ctxKeyRequest struct{}

// withRequest stores the request for the subject resolver.
func withRequest(r *http.Request) context.Context {
	return context.WithValue(r.Context(), ctxKeyRequest{}, r)
}

// personOf resolves the authenticated person (fail closed).
func personOf(r *http.Request, res SubjectResolver) (string, error) {
	return res.PersonID(withRequest(r))
}
