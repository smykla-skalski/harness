use serde::{Deserialize, Serialize};

use super::super::dispatch::DispatchExecutionSummary;
use super::super::evaluation::TaskBoardEvaluationSummary;
use super::super::summary::{TaskBoardAuditSummary, TaskBoardSyncSummary};
use super::super::types::TaskBoardStatus;
use super::super::{TaskBoardPolicyCompilationError, validate_task_board_policy};

/// Settings' `github_project` field, kept under its old name because that is
/// what the stored JSON and the generated client still call it. The type behind
/// it names no repository: publication builds a `GitHubProjectConfig` per item
/// through `GitHubAutomationSettings::for_repository`.
pub use crate::github::GitHubAutomationSettings as TaskBoardGitHubProjectConfig;

// `TaskBoardOrchestratorSettings`/`TaskBoardOrchestratorSettingsUpdateRequest`/
// `TaskBoardOrchestratorRunOnceRequest`/`TaskBoardGitHubInboxConfig`/
// `TaskBoardHeldDispatchSummary`/`TaskBoardHeldDispatchItem`/
// `TaskBoardOrchestratorTickInfo`/`TaskBoardOrchestratorTickPhase`/
// `TaskBoardOrchestratorRunStatus`/`TaskBoardWorkflowExecutionCount` relocated
// to `harness_protocol::daemon::task_board::orchestrator` (#1145): pure data,
// needed there because `TaskBoardOrchestratorStatus` embeds
// `TaskBoardOrchestratorSettings` directly. `TaskBoardOrchestratorStatusSnapshot`
// (below) stays here: it embeds `DispatchExecutionSummary`/
// `TaskBoardEvaluationSummary`, which in turn embed the full `TaskBoardItem`
// domain entity. `TaskBoardOrchestratorSettingsUpdateRequest`'s
// `validate_admission_policy` inherent method could not come along - a new
// inherent method can only be added in the type's defining crate - so it
// became the free function `validate_orchestrator_settings_update_admission_policy`
// below.
pub use harness_protocol::daemon::task_board::orchestrator::{
    TaskBoardGitHubInboxConfig, TaskBoardHeldDispatchItem, TaskBoardHeldDispatchSummary,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorRunStatus,
    TaskBoardOrchestratorSettings, TaskBoardOrchestratorSettingsUpdateRequest,
    TaskBoardOrchestratorTickInfo, TaskBoardOrchestratorTickPhase, TaskBoardWorkflowExecutionCount,
};

pub const CURRENT_ORCHESTRATOR_STATE_VERSION: u32 = 1;

#[cfg(test)]
#[path = "types_tests.rs"]
mod tests;

/// The orchestrator's full in-process status: what the daemon builds,
/// mutates, and persists internally. Its embedded `last_run` carries the
/// full `TaskBoardItem` (via `DispatchAppliedTask`/`TaskBoardEvaluationRecord`).
/// The wire-facing `TaskBoardOrchestratorStatus`
/// (`crate::wire::task_board_orchestrator_status`) is a separate, thin
/// projection of this type, produced at the HTTP/WS boundary, that drops
/// the embedded item down to the id and title real consumers use.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorStatusSnapshot {
    pub enabled: bool,
    pub running: bool,
    #[serde(default)]
    pub step_mode: bool,
    #[serde(default)]
    pub held_dispatches: TaskBoardHeldDispatchSummary,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_tick: Option<TaskBoardOrchestratorTickInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run: Option<TaskBoardOrchestratorRunSummary>,
    pub workflow_execution_counts: Vec<TaskBoardWorkflowExecutionCount>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub automation: Option<super::super::TaskBoardAutomationSnapshot>,
    pub settings: TaskBoardOrchestratorSettings,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardOrchestratorState {
    #[serde(default = "default_state_schema_version")]
    pub schema_version: u32,
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub running: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_tick: Option<TaskBoardOrchestratorTickInfo>,
    #[serde(
        default,
        deserialize_with = "readable_last_run",
        skip_serializing_if = "Option::is_none"
    )]
    pub last_run: Option<TaskBoardOrchestratorRunSummary>,
}

/// A finished run is history, so it can name a provider or status that a later
/// build no longer has a variant for. Parsing it strictly makes one stale row
/// fatal to daemon startup, which is how removing the Todoist provider left
/// existing installs crash-looping before they could publish a manifest.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn readable_last_run<'de, D>(
    deserializer: D,
) -> Result<Option<TaskBoardOrchestratorRunSummary>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let Some(recorded) = Option::<serde_json::Value>::deserialize(deserializer)? else {
        return Ok(None);
    };
    Ok(serde_json::from_value(recorded)
        .inspect_err(|error| {
            tracing::warn!(%error, "dropping an unreadable task board last-run record");
        })
        .ok())
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorRunSummary {
    pub run_id: String,
    pub started_at: String,
    pub completed_at: String,
    pub status: TaskBoardOrchestratorRunStatus,
    pub dry_run: bool,
    pub sync: TaskBoardSyncSummary,
    pub audit: TaskBoardAuditSummary,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch: Option<DispatchExecutionSummary>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evaluation: Option<TaskBoardEvaluationSummary>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_trace_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardOrchestratorDispatchInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
    pub status: Option<TaskBoardStatus>,
    pub dry_run: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardOrchestratorPreparedRun {
    pub run_id: String,
    pub started_at: String,
    pub input: TaskBoardOrchestratorDispatchInput,
    pub sync: TaskBoardSyncSummary,
    pub audit: TaskBoardAuditSummary,
}

impl Default for TaskBoardOrchestratorState {
    fn default() -> Self {
        Self {
            schema_version: default_state_schema_version(),
            enabled: false,
            running: false,
            current_tick: None,
            last_run: None,
        }
    }
}

const fn default_state_schema_version() -> u32 {
    CURRENT_ORCHESTRATOR_STATE_VERSION
}

impl TaskBoardOrchestratorStatusSnapshot {
    #[must_use]
    pub fn last_run_applied_count(&self) -> usize {
        self.last_run.as_ref().map_or(0, |run| {
            let synced = run
                .sync
                .operations
                .iter()
                .filter(|operation| operation.applied)
                .count();
            let dispatched = run
                .dispatch
                .as_ref()
                .map_or(0, |dispatch| dispatch.applied.len());
            let evaluated = run
                .evaluation
                .as_ref()
                .map_or(0, |evaluation| evaluation.updated);
            synced + dispatched + evaluated
        })
    }
}

/// Validate the complete replacement admission policy, when supplied.
///
/// Free function because `TaskBoardOrchestratorSettingsUpdateRequest` moved to
/// `harness-protocol` (#1145), and a new inherent method can only be added to
/// a type in its defining crate; `validate_task_board_policy` itself stays
/// here since it reaches `normalize_repository_slug` and admission-requirement
/// state this move has no need for.
///
/// # Errors
/// Returns the first deterministic whole-policy validation error.
pub fn validate_orchestrator_settings_update_admission_policy(
    request: &TaskBoardOrchestratorSettingsUpdateRequest,
) -> Result<(), TaskBoardPolicyCompilationError> {
    request
        .admission_policy
        .as_ref()
        .map_or(Ok(()), validate_task_board_policy)
}
