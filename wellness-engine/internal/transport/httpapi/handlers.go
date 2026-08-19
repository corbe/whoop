// Handlers — thin HTTP → application mapping (STAGE 17).
package httpapi

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/application"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/domain"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/engine"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/repository"
	"github.com/noana-org/noana-wellness-app/wellness-engine/internal/versioning"
)

// Server wires routes, auth and the application service.
type Server struct {
	svc      *application.WellnessService
	subject  SubjectResolver
	internal InternalAuth
	ready    func() error // persistence readiness probe
}

// New builds the server. ready may be nil (assumes ok).
func New(svc *application.WellnessService, subject SubjectResolver, internal InternalAuth, ready func() error) *Server {
	return &Server{svc: svc, subject: subject, internal: internal, ready: ready}
}

// Handler returns the root http.Handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("POST /v1/wellness/days/{date}/calculate", s.handleCalculate)
	mux.HandleFunc("GET /v1/wellness/days/{date}/scores", s.handleScores)
	mux.HandleFunc("GET /v1/wellness/days/{date}/scores/{formula}", s.handleScoreDetail)
	mux.HandleFunc("GET /v1/wellness/days/{date}/scores/{formula}/history", s.handleScoreHistory)
	mux.HandleFunc("GET /v1/wellness/goals/current", s.handleGoalsCurrent)
	mux.HandleFunc("GET /v1/wellness/goals/history/{goal}", s.handleGoalsHistory)
	mux.HandleFunc("GET /v1/wellness/baseline/current", s.handleBaseline)
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /ready", s.handleReady)

	// internal (admin) routes — separate namespace, never user-authable
	imux := http.NewServeMux()
	imux.HandleFunc("GET /internal/v1/formulas", s.handleInternalFormulas)
	mux.Handle("/internal/", s.internalOnly(imux))

	return mux
}

// ── calculate ──────────────────────────────────────────────────────────────

func (s *Server) handleCalculate(w http.ResponseWriter, r *http.Request) {
	person, err := personOf(r, s.subject)
	if err != nil {
		mapError(w, r, err)
		return
	}
	day, err := parseDate(r.PathValue("date"))
	if err != nil {
		mapError(w, r, domain.InvalidInput("%s", err))
		return
	}
	var req calculateRequest
	if r.Body != nil && r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			mapError(w, r, err)
			return
		}
	}
	// identity: authenticated subject wins; body person_id must match
	if req.PersonID != "" && req.PersonID != person {
		mapError(w, r, errForbidden)
		return
	}

	var raw *engine.Input
	if req.Raw != nil {
		in, err := req.Raw.toEngineInput(day)
		if err != nil {
			mapError(w, r, domain.InvalidInput("%s", err))
			return
		}
		raw = &in
	}
	res, err := s.svc.CalculateDay(r.Context(), person, day, raw)
	if err != nil {
		mapError(w, r, err)
		return
	}
	status := http.StatusCreated
	if res.Replay {
		status = http.StatusOK
	}
	writeJSON(w, status, calculateResponse{
		PersonID:         person,
		Date:             day.Format("2006-01-02"),
		Timezone:         res.Run.Timezone,
		Replay:           res.Replay,
		RunID:            res.Run.RunID,
		ReplacesRunID:    res.Run.ReplacesRunID,
		InputFingerprint: res.Run.InputFingerprint,
		ConfigHash:       res.Bundle.Metadata.ConfigHash,
		EngineVersion:    res.Bundle.Metadata.EngineVersion,
		Scores:           scoreRefs(res.Bundle),
		GoalUpdates:      goalUpdatesOf(res.Bundle),
		Quality:          qualityOf(res.Bundle),
	})
}

// ── scores ─────────────────────────────────────────────────────────────────

func (s *Server) handleScores(w http.ResponseWriter, r *http.Request) {
	person, day, ok := s.authDay(w, r)
	if !ok {
		return
	}
	scores, err := s.svc.GetDailyScores(r.Context(), person, day)
	if err != nil {
		mapError(w, r, err)
		return
	}
	meta := s.runMetaIndex(w, r, person, day)
	out := scoresResponse{PersonID: person, Date: day.Format("2006-01-02"), Scores: map[string]*scoreDTO{}}
	for key, sc := range scores {
		out.Scores[key] = &scoreDTO{
			RunID:          sc.RunID,
			Score:          sc.Score,
			FormulaVersion: sc.FormulaVersion,
			ConfigHash:     sc.ConfigHash,
			EngineVersion:  meta[sc.RunID].EngineVersion,
			CalculatedAt:   meta[sc.RunID].CalculatedAt,
			IsCurrent:      sc.IsCurrent,
		}
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleScoreDetail(w http.ResponseWriter, r *http.Request) {
	person, day, ok := s.authDay(w, r)
	if !ok {
		return
	}
	formula := r.PathValue("formula")
	sc, err := s.svc.GetScoreDetail(r.Context(), person, day, formula)
	if err != nil {
		mapError(w, r, err)
		return
	}
	var raw explanationDTO
	if err := json.Unmarshal(sc.Explanation, &raw); err != nil {
		mapError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, detailResponse{
		PersonID:    person,
		Date:        day.Format("2006-01-02"),
		RunID:       sc.RunID,
		Explanation: raw,
	})
}

func (s *Server) handleScoreHistory(w http.ResponseWriter, r *http.Request) {
	person, day, ok := s.authDay(w, r)
	if !ok {
		return
	}
	formula := r.PathValue("formula")
	hist, err := s.svc.GetScoreHistory(r.Context(), person, day, formula)
	if err != nil {
		mapError(w, r, err)
		return
	}
	revisions := make([]revisionDTO, 0, len(hist))
	for _, h := range hist {
		revisions = append(revisions, revisionDTO{
			RunID:            h.Score.RunID,
			Score:            h.Score.Score,
			FormulaVersion:   h.Score.FormulaVersion,
			ConfigHash:       h.Score.ConfigHash,
			InputFingerprint: h.InputFingerprint,
			EngineVersion:    h.EngineVersion,
			CalculatedAt:     h.CalculatedAt,
			IsCurrent:        h.Score.IsCurrent,
			ReplacesRunID:    h.ReplacesRunID,
		})
	}
	writeJSON(w, http.StatusOK, historyResponse{PersonID: person, Date: day.Format("2006-01-02"), Formula: formula, Revisions: revisions})
}

// ── goals / baseline ───────────────────────────────────────────────────────

func (s *Server) handleGoalsCurrent(w http.ResponseWriter, r *http.Request) {
	person, err := personOf(r, s.subject)
	if err != nil {
		mapError(w, r, err)
		return
	}
	goals, err := s.svc.GetCurrentGoals(r.Context(), person)
	if err != nil {
		mapError(w, r, err)
		return
	}
	out := goalsCurrentResponse{PersonID: person, Goals: map[string]*goalDTO{}}
	for key, g := range goals {
		out.Goals[key] = goalDTOOf(g)
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleGoalsHistory(w http.ResponseWriter, r *http.Request) {
	person, err := personOf(r, s.subject)
	if err != nil {
		mapError(w, r, err)
		return
	}
	goalKey := r.PathValue("goal")
	changes, err := s.svc.GetGoalHistory(r.Context(), person, goalKey)
	if err != nil {
		mapError(w, r, err)
		return
	}
	out := goalsHistoryResponse{PersonID: person, GoalKey: goalKey, Changes: []goalDTO{}}
	for i := range changes {
		out.Changes = append(out.Changes, *goalDTOOf(&changes[i]))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleBaseline(w http.ResponseWriter, r *http.Request) {
	person, err := personOf(r, s.subject)
	if err != nil {
		mapError(w, r, err)
		return
	}
	bs, err := s.svc.GetCurrentBaseline(r.Context(), person)
	if err != nil {
		mapError(w, r, err)
		return
	}
	if bs == nil {
		mapError(w, r, errNotFound)
		return
	}
	writeJSON(w, http.StatusOK, baselineResponse{
		PersonID: person, LogicalDay: bs.LogicalDay.Format("2006-01-02"),
		RunID: bs.RunID, Metrics: bs.Metrics,
	})
}

// ── health / ready / internal ──────────────────────────────────────────────

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, healthResponse{Status: "ok", EngineVersion: versioning.EngineVersion})
}

func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
	if s.ready == nil {
		writeJSON(w, http.StatusOK, readyResponse{Status: "ok", Persistence: "ok"})
		return
	}
	if err := s.ready(); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, readyResponse{Status: "unavailable", Persistence: "unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, readyResponse{Status: "ok", Persistence: "ok"})
}

func (s *Server) internalOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.internal.Authorize(r) {
			mapError(w, r, errForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) handleInternalFormulas(w http.ResponseWriter, _ *http.Request) {
	type fv struct {
		FormulaKey string `json:"formula_key"`
		Version    int    `json:"version"`
		Status     string `json:"status"`
		Name       string `json:"name"`
	}
	reg := versioning.DefaultRegistry()
	out := []fv{}
	for _, key := range []versioning.Key{versioning.KeySleep, versioning.KeyStress,
		versioning.KeyReadiness, versioning.KeyActivity, versioning.KeyGoalSteps, versioning.KeyGoalSleep} {
		v := reg.Active(key)
		out = append(out, fv{FormulaKey: string(key), Version: v.Version, Status: v.Status.String(), Name: v.Name})
	}
	writeJSON(w, http.StatusOK, map[string]any{"formulas": out})
}

// ── helpers ────────────────────────────────────────────────────────────────

// authDay resolves the authenticated person + validates the day path param.
func (s *Server) authDay(w http.ResponseWriter, r *http.Request) (string, time.Time, bool) {
	person, err := personOf(r, s.subject)
	if err != nil {
		mapError(w, r, err)
		return "", time.Time{}, false
	}
	day, err := parseDate(r.PathValue("date"))
	if err != nil {
		mapError(w, r, domain.InvalidInput("%s", err))
		return "", time.Time{}, false
	}
	return person, day, true
}

// runMetaIndex loads the run revision index for the request's person/day.
func (s *Server) runMetaIndex(w http.ResponseWriter, r *http.Request, person string, day time.Time) map[int64]runMeta {
	runs, err := s.svc.GetRunRevisions(r.Context(), person, day)
	if err != nil {
		return map[int64]runMeta{}
	}
	idx := make(map[int64]runMeta, len(runs))
	for _, rn := range runs {
		idx[rn.RunID] = runMeta{EngineVersion: rn.EngineVersion, CalculatedAt: rn.CalculatedAt}
	}
	return idx
}

type runMeta struct {
	EngineVersion string
	CalculatedAt  time.Time
}

func scoreRefs(b *engine.CalculationBundle) map[string]scoreRefDTO {
	scores := make(map[string]scoreRefDTO, 4)
	for key, ex := range b.Explanations {
		scores[string(key)] = scoreRefDTO{Score: ex.Score, FormulaVersion: ex.FormulaVersion}
	}
	return scores
}

func goalUpdatesOf(b *engine.CalculationBundle) []goalUpdateDTO {
	var out []goalUpdateDTO
	if b.Goals.Steps.Updated && b.Goals.Steps.NewGoal != nil {
		out = append(out, goalUpdateDTO{GoalKey: "goal_steps", Value: *b.Goals.Steps.NewGoal,
			Reason: string(b.Goals.Steps.Reason), Source: "auto"})
	}
	if b.Goals.Sleep.Updated && b.Goals.Sleep.NewSleepTarget != nil {
		out = append(out, goalUpdateDTO{GoalKey: "goal_sleep", Value: *b.Goals.Sleep.NewSleepTarget,
			Reason: string(b.Goals.Sleep.Reason), Source: "auto"})
	}
	return out
}

func qualityOf(b *engine.CalculationBundle) qualityDTO {
	q := qualityDTO{}
	for _, w := range b.Quality.Warnings {
		q.Warnings = append(q.Warnings, w.Code)
	}
	for _, m := range b.Quality.Missing {
		q.Missing = append(q.Missing, string(m))
	}
	return q
}

func goalDTOOf(g *repository.Goal) *goalDTO {
	return &goalDTO{
		GoalKey: g.GoalKey, Value: g.Value, BedTimeMinutes: g.BedTimeMinutes,
		Reason: g.Reason, Source: g.Source, FormulaKey: g.FormulaKey,
		ConfigHash: g.ConfigHash, AppliedAt: g.AppliedAt,
	}
}
