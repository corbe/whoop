// Stable API DTOs (STAGE 17.11) — never marshal DB models or engine structs
// directly. JSON shapes follow docs/wellness-api-design.md.
package httpapi

import (
	"encoding/json"
	"time"
)

// ── calculate ──────────────────────────────────────────────────────────────

// calculateRequest mode B (stateless raw input). Mode A sends
// {"person_id"} only and the server resolves via RawInputProvider.
type calculateRequest struct {
	// PersonID is accepted ONLY when the auth subject is empty/test mode —
	// production must derive the person from the auth context. The handler
	// enforces: subject wins; a mismatched body person_id → 403.
	PersonID string       `json:"person_id,omitempty"`
	Raw      *rawInputDTO `json:"input,omitempty"` // mode B
}

// rawInputDTO mirrors the CLI input wire format (see
// wellness-engine/testdata/example-day.json).
type rawInputDTO struct {
	Timezone             string    `json:"timezone"`
	Segments             []segDTO  `json:"segments,omitempty"`
	DailyHrvAverages     []float64 `json:"daily_hrv_averages_ms,omitempty"`
	SleepHistoryScores   []int     `json:"sleep_history_scores,omitempty"`
	FatigueHistoryScores []int     `json:"fatigue_history_scores,omitempty"`
	LastNightRhr         *float64  `json:"last_night_rhr_bpm,omitempty"`
	RhrBaseline          *float64  `json:"rhr_baseline_bpm,omitempty"`
	Spo2Tonight          *float64  `json:"spo2_tonight_pct,omitempty"`
	Spo2Baseline         *float64  `json:"spo2_baseline_pct,omitempty"`
	Steps                []stepDTO `json:"steps,omitempty"`
	SessionKcal          int       `json:"session_kcal,omitempty"`
	GoalSteps            int       `json:"goal_steps,omitempty"`
	// Goal auto-update inputs (F-08/F-09; optional)
	GoalStepSamples       []int `json:"goal_step_samples_d1_d30,omitempty"`
	GoalPriorSteps        int   `json:"goal_prior_steps,omitempty"`
	GoalMaxDailySteps     int   `json:"goal_max_daily_steps,omitempty"`
	GoalCurrentSteps      int   `json:"goal_current_steps,omitempty"`
	GoalLastAutoUpdateAt  int64 `json:"goal_last_auto_update_at_ms,omitempty"`
	GoalManualOverrideAt  int64 `json:"goal_manual_override_at_ms,omitempty"`
	BedtimeMinutes        []int `json:"bedtime_minutes_d1_d21,omitempty"`
	DurationMinutes       []int `json:"duration_minutes_d1_d21,omitempty"`
	SleepCurrentBedTime   *int  `json:"sleep_current_bed_time_minutes,omitempty"`
	SleepCurrentTarget    *int  `json:"sleep_current_target_minutes,omitempty"`
	SleepLastAutoUpdateAt int64 `json:"sleep_last_auto_update_at_ms,omitempty"`
	NowMs                 int64 `json:"now_ms,omitempty"`
}

type segDTO struct {
	StartMs int64 `json:"start_ms"`
	EndMs   int64 `json:"end_ms"`
	Stage   int8  `json:"stage"`
}

type stepDTO struct {
	Value     float64 `json:"value"`
	Calories  float64 `json:"calories,omitempty"`
	DistanceM float64 `json:"distance_m,omitempty"`
	Timestamp int64   `json:"timestamp"`
	Device    string  `json:"device,omitempty"`
}

type scoreRefDTO struct {
	Score          int `json:"score"`
	FormulaVersion int `json:"formula_version"`
}

type goalUpdateDTO struct {
	GoalKey string `json:"goal_key"`
	Value   int    `json:"value"`
	Reason  string `json:"reason"`
	Source  string `json:"source"`
}

type qualityDTO struct {
	Warnings []string `json:"warnings,omitempty"`
	Missing  []string `json:"missing,omitempty"`
}

type calculateResponse struct {
	PersonID         string                 `json:"person_id"`
	Date             string                 `json:"date"`
	Timezone         string                 `json:"timezone,omitempty"`
	Replay           bool                   `json:"replay"`
	RunID            int64                  `json:"run_id"`
	ReplacesRunID    *int64                 `json:"replaces_run_id,omitempty"`
	InputFingerprint string                 `json:"input_fingerprint"`
	ConfigHash       string                 `json:"config_hash"`
	EngineVersion    string                 `json:"engine_version"`
	Scores           map[string]scoreRefDTO `json:"scores"`
	GoalUpdates      []goalUpdateDTO        `json:"goal_updates,omitempty"`
	Quality          qualityDTO             `json:"quality"`
}

// ── scores ─────────────────────────────────────────────────────────────────

type scoreDTO struct {
	RunID          int64     `json:"run_id"`
	Score          int       `json:"score"`
	FormulaVersion int       `json:"formula_version"`
	ConfigHash     string    `json:"config_hash"`
	EngineVersion  string    `json:"engine_version"`
	CalculatedAt   time.Time `json:"calculated_at"`
	IsCurrent      bool      `json:"is_current"`
}

type scoresResponse struct {
	PersonID string               `json:"person_id"`
	Date     string               `json:"date"`
	Scores   map[string]*scoreDTO `json:"scores"` // null when no current row
}

// ── detail ─────────────────────────────────────────────────────────────────

type explanationDTO struct {
	Score          int               `json:"score"`
	FormulaKey     string            `json:"formula_key"`
	FormulaVersion int               `json:"formula_version"`
	ConfigHash     string            `json:"config_hash"`
	EngineVersion  string            `json:"engine_version"`
	CalculatedAt   time.Time         `json:"calculated_at"`
	Components     []json.RawMessage `json:"components,omitempty"`
	Steps          []json.RawMessage `json:"steps,omitempty"`
	Warnings       []json.RawMessage `json:"warnings,omitempty"`
	Missing        []string          `json:"missing,omitempty"`
}

type detailResponse struct {
	PersonID    string         `json:"person_id"`
	Date        string         `json:"date"`
	RunID       int64          `json:"run_id"`
	Explanation explanationDTO `json:"explanation"`
}

// ── history ────────────────────────────────────────────────────────────────

type revisionDTO struct {
	RunID            int64     `json:"run_id"`
	Score            int       `json:"score"`
	FormulaVersion   int       `json:"formula_version"`
	ConfigHash       string    `json:"config_hash"`
	InputFingerprint string    `json:"input_fingerprint,omitempty"`
	EngineVersion    string    `json:"engine_version"`
	CalculatedAt     time.Time `json:"calculated_at"`
	IsCurrent        bool      `json:"is_current"`
	ReplacesRunID    *int64    `json:"replaces_run_id,omitempty"`
}

type historyResponse struct {
	PersonID  string        `json:"person_id"`
	Date      string        `json:"date"`
	Formula   string        `json:"formula"`
	Revisions []revisionDTO `json:"revisions"`
}

// ── goals / baseline ───────────────────────────────────────────────────────

type goalDTO struct {
	GoalKey        string    `json:"goal_key"`
	Value          int       `json:"value"`
	BedTimeMinutes *int      `json:"bed_time_minutes,omitempty"`
	Reason         string    `json:"reason"`
	Source         string    `json:"source"`
	FormulaKey     string    `json:"formula_key,omitempty"`
	ConfigHash     string    `json:"config_hash,omitempty"`
	AppliedAt      time.Time `json:"applied_at"`
}

type goalsCurrentResponse struct {
	PersonID string              `json:"person_id"`
	Goals    map[string]*goalDTO `json:"goals"`
}

type goalsHistoryResponse struct {
	PersonID string    `json:"person_id"`
	GoalKey  string    `json:"goal_key"`
	Changes  []goalDTO `json:"changes"`
}

type baselineResponse struct {
	PersonID   string          `json:"person_id"`
	LogicalDay string          `json:"logical_day"`
	RunID      int64           `json:"run_id"`
	Metrics    json.RawMessage `json:"metrics"`
}

// ── health ─────────────────────────────────────────────────────────────────

type healthResponse struct {
	Status        string `json:"status"`
	EngineVersion string `json:"engine_version"`
}

type readyResponse struct {
	Status      string `json:"status"`
	Persistence string `json:"persistence"` // ok | unavailable
}
