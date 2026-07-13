use serde::{Deserialize, Serialize};

use super::super::dispatch::DispatchExecutionSummary;
use super::super::evaluation::TaskBoardEvaluationSummary;
use super::super::policy::POLICY_VERSION;
use super::super::summary::{TaskBoardAuditSummary, TaskBoardSyncSummary};
use super::super::types::{TaskBoardStatus, TaskBoardWorkflowStatus};

pub use crate::task_board::github::GitHubProjectConfig as TaskBoardGitHubProjectConfig;

pub const CURRENT_ORCHESTRATOR_STATE_VERSION: u32 = 1;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardGitHubInboxConfig {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repositories: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub label_filter: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardTodoistInboxConfig {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub project_filter: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardOrchestratorSettings {
    #[serde(default)]
    pub step_mode: bool,
    #[serde(default = "default_enabled_workflows")]
    pub enabled_workflows: Vec<TaskBoardOrchestratorWorkflow>,
    #[serde(default = "default_dry_run_default")]
    pub dry_run_default: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch_status_filter: Option<TaskBoardStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
    #[serde(default)]
    pub github_project: TaskBoardGitHubProjectConfig,
    #[serde(default)]
    pub github_inbox: TaskBoardGitHubInboxConfig,
    #[serde(default)]
    pub todoist_inbox: TaskBoardTodoistInboxConfig,
    #[serde(default = "default_policy_version")]
    pub policy_version: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardOrchestratorSettingsUpdateRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step_mode: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled_workflows: Option<Vec<TaskBoardOrchestratorWorkflow>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dry_run_default: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch_status_filter: Option<TaskBoardStatus>,
    #[serde(default)]
    pub clear_dispatch_status_filter: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
    #[serde(default)]
    pub clear_project_dir: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub github_project: Option<TaskBoardGitHubProjectConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub github_inbox: Option<TaskBoardGitHubInboxConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub todoist_inbox: Option<TaskBoardTodoistInboxConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_version: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardOrchestratorWorkflow {
    DefaultTask,
    PrFix,
    PrReview,
    Review,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardOrchestratorRunOnceRequest {
    #[serde(default, alias = "id", skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dry_run: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardOrchestratorStatus {
    pub enabled: bool,
    pub running: bool,
    #[serde(default)]
    pub step_mode: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_tick: Option<TaskBoardOrchestratorTickInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run: Option<TaskBoardOrchestratorRunSummary>,
    pub workflow_execution_counts: Vec<TaskBoardWorkflowExecutionCount>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run: Option<TaskBoardOrchestratorRunSummary>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskBoardOrchestratorTickInfo {
    pub run_id: String,
    pub phase: TaskBoardOrchestratorTickPhase,
    pub started_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    pub dry_run: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardOrchestratorTickPhase {
    Starting,
    Dispatch,
    Evaluation,
    Completed,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardOrchestratorRunStatus {
    Completed,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardWorkflowExecutionCount {
    pub status: TaskBoardWorkflowStatus,
    pub count: usize,
}

impl Default for TaskBoardOrchestratorSettings {
    fn default() -> Self {
        Self {
            step_mode: false,
            enabled_workflows: default_enabled_workflows(),
            dry_run_default: default_dry_run_default(),
            dispatch_status_filter: Some(TaskBoardStatus::Todo),
            project_dir: None,
            github_project: TaskBoardGitHubProjectConfig::default(),
            github_inbox: TaskBoardGitHubInboxConfig::default(),
            todoist_inbox: TaskBoardTodoistInboxConfig::default(),
            policy_version: default_policy_version(),
        }
    }
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

fn default_enabled_workflows() -> Vec<TaskBoardOrchestratorWorkflow> {
    vec![
        TaskBoardOrchestratorWorkflow::DefaultTask,
        TaskBoardOrchestratorWorkflow::PrFix,
        TaskBoardOrchestratorWorkflow::PrReview,
        TaskBoardOrchestratorWorkflow::Review,
    ]
}

const fn default_dry_run_default() -> bool {
    true
}

fn default_policy_version() -> String {
    POLICY_VERSION.to_string()
}

const fn default_state_schema_version() -> u32 {
    CURRENT_ORCHESTRATOR_STATE_VERSION
}

impl TaskBoardOrchestratorStatus {
    #[must_use]
    pub fn last_run_applied_count(&self) -> usize {
        self.last_run.as_ref().map_or(0, |run| {
            let dispatched = run
                .dispatch
                .as_ref()
                .map_or(0, |dispatch| dispatch.applied.len());
            let evaluated = run
                .evaluation
                .as_ref()
                .map_or(0, |evaluation| evaluation.updated);
            dispatched + evaluated
        })
    }
}
