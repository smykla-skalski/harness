//! Task-board orchestrator settings and run bookkeeping, relocated here from
//! `harness-task-board::orchestrator::types`. `TaskBoardOrchestratorStatusSnapshot`,
//! `TaskBoardOrchestratorState`, `TaskBoardOrchestratorRunSummary`,
//! `TaskBoardOrchestratorDispatchInput`, and `TaskBoardOrchestratorPreparedRun`
//! stay in `harness-task-board`: they embed `DispatchExecutionSummary`/
//! `TaskBoardEvaluationSummary`, which in turn embed the full `TaskBoardItem`
//! domain entity, and `TaskBoardOrchestratorState`'s own schema-versioned
//! persistence format has not moved. `TaskBoardOrchestratorSettingsUpdateRequest`'s
//! `validate_admission_policy` inherent method could not come along for the
//! same reason `automation::policy_compiler`'s engine stayed behind: it
//! stayed as the free function `validate_orchestrator_settings_update_admission_policy`
//! in `harness-task-board::orchestrator`. `harness-task-board` re-exports
//! every type name below at the same path.

use serde::{Deserialize, Serialize};

use super::automation_settings::{
    TaskBoardAutomationRetrySettings, TaskBoardAutomationSchedulingSettings,
    TaskBoardExecutionHostConfig, TaskBoardLocalExecutionHostConfig,
    TaskBoardRepositoryAutomationConfig, TaskBoardReviewerSettings,
};
use super::github_config::GitHubAutomationSettings;
use super::orchestrator_workflow::TaskBoardOrchestratorWorkflow;
use super::policy_decision::POLICY_VERSION;
use super::policy_scope::TaskBoardAutomationPolicy;
use super::types::{TaskBoardStatus, TaskBoardWorkflowStatus};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardGitHubInboxConfig {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repositories: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub label_filter: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorSettings {
    #[serde(default)]
    pub step_mode: bool,
    #[serde(default = "default_triage_automation_enabled")]
    pub triage_automation_enabled: bool,
    #[serde(default = "default_enabled_workflows")]
    pub enabled_workflows: Vec<TaskBoardOrchestratorWorkflow>,
    #[serde(default = "default_dry_run_default")]
    pub dry_run_default: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch_status_filter: Option<TaskBoardStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
    #[serde(default)]
    pub github_project: GitHubAutomationSettings,
    #[serde(default)]
    pub github_inbox: TaskBoardGitHubInboxConfig,
    #[serde(default)]
    pub scheduling: TaskBoardAutomationSchedulingSettings,
    #[serde(default)]
    pub retry: TaskBoardAutomationRetrySettings,
    #[serde(default)]
    pub reviewers: TaskBoardReviewerSettings,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repositories: Vec<TaskBoardRepositoryAutomationConfig>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub execution_hosts: Vec<TaskBoardExecutionHostConfig>,
    #[serde(default)]
    pub local_execution_host: TaskBoardLocalExecutionHostConfig,
    #[serde(default)]
    pub admission_policy: TaskBoardAutomationPolicy,
    #[serde(default = "default_policy_version")]
    pub policy_version: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorSettingsUpdateRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step_mode: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub triage_automation_enabled: Option<bool>,
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
    pub github_project: Option<GitHubAutomationSettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub github_inbox: Option<TaskBoardGitHubInboxConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scheduling: Option<TaskBoardAutomationSchedulingSettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry: Option<TaskBoardAutomationRetrySettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reviewers: Option<TaskBoardReviewerSettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repositories: Option<Vec<TaskBoardRepositoryAutomationConfig>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_hosts: Option<Vec<TaskBoardExecutionHostConfig>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub local_execution_host: Option<TaskBoardLocalExecutionHostConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub admission_policy: Option<TaskBoardAutomationPolicy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_version: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
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

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardHeldDispatchSummary {
    pub count: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub items: Vec<TaskBoardHeldDispatchItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardHeldDispatchItem {
    pub intent_id: String,
    pub board_item_id: String,
    pub session_id: String,
    pub work_item_id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, utoipa::ToSchema)]
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
#[derive(utoipa::ToSchema)]
pub enum TaskBoardOrchestratorTickPhase {
    Starting,
    Dispatch,
    Evaluation,
    Completed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardOrchestratorRunStatus {
    Completed,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardWorkflowExecutionCount {
    pub status: TaskBoardWorkflowStatus,
    pub count: usize,
}

impl Default for TaskBoardOrchestratorSettings {
    fn default() -> Self {
        Self {
            step_mode: false,
            triage_automation_enabled: true,
            enabled_workflows: default_enabled_workflows(),
            dry_run_default: default_dry_run_default(),
            dispatch_status_filter: Some(TaskBoardStatus::Todo),
            project_dir: None,
            github_project: GitHubAutomationSettings::default(),
            github_inbox: TaskBoardGitHubInboxConfig::default(),
            scheduling: TaskBoardAutomationSchedulingSettings::default(),
            retry: TaskBoardAutomationRetrySettings::default(),
            reviewers: TaskBoardReviewerSettings::default(),
            repositories: Vec::new(),
            execution_hosts: Vec::new(),
            local_execution_host: TaskBoardLocalExecutionHostConfig::default(),
            admission_policy: TaskBoardAutomationPolicy::default(),
            policy_version: default_policy_version(),
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

const fn default_triage_automation_enabled() -> bool {
    true
}

fn default_policy_version() -> String {
    POLICY_VERSION.to_string()
}

// Existing coverage for these types stays in
// `harness-task-board::orchestrator::types`'s own `#[path]` test module,
// exercised through the re-export below.
