//! Durable task-board automation settings, relocated here unchanged from
//! `harness-task-board::automation::settings`. Pure data plus trivial
//! `Default` impls; `harness-task-board` re-exports every name below at the
//! same path.

use serde::{Deserialize, Serialize};

use super::orchestrator_workflow::{
    TaskBoardOrchestratorWorkflow, TaskBoardPhaseCapabilityProfile,
};
use super::types::AgentMode;
use crate::daemon::task_board::github_config::{
    GitHubAutomationLabels, GitHubAutomationToggles, GitHubRequestedReviewers, ProtectedPathRule,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAutomationSchedulingSettings {
    pub max_dispatches_per_run: u32,
    pub max_concurrent_workflows: u32,
    pub reconcile_interval_seconds: u64,
}

impl Default for TaskBoardAutomationSchedulingSettings {
    fn default() -> Self {
        Self {
            max_dispatches_per_run: 1,
            max_concurrent_workflows: 1,
            reconcile_interval_seconds: 60,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAutomationRetrySettings {
    pub max_attempts: u32,
    pub base_delay_seconds: u64,
    pub multiplier: u32,
    pub max_delay_seconds: u64,
    pub deterministic_jitter_percent: u8,
}

impl Default for TaskBoardAutomationRetrySettings {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            base_delay_seconds: 30,
            multiplier: 4,
            max_delay_seconds: 600,
            deterministic_jitter_percent: 10,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardReviewerProfile {
    pub id: String,
    pub runtime: String,
    pub persona: String,
    pub agent_mode: AgentMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
}

impl Default for TaskBoardReviewerProfile {
    fn default() -> Self {
        Self {
            id: "default-code-reviewer".into(),
            runtime: "codex".into(),
            persona: "code-reviewer".into(),
            agent_mode: AgentMode::Evaluate,
            model: None,
            effort: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardReviewerRule {
    pub workflow: TaskBoardOrchestratorWorkflow,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    pub reviewer_count: u32,
    pub required_approvals: u32,
    pub profiles: Vec<TaskBoardReviewerProfile>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardReviewerSettings {
    pub reviewer_count: u32,
    pub required_approvals: u32,
    pub max_revision_cycles: u32,
    pub profiles: Vec<TaskBoardReviewerProfile>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub overrides: Vec<TaskBoardReviewerRule>,
}

impl Default for TaskBoardReviewerSettings {
    fn default() -> Self {
        Self {
            reviewer_count: 1,
            required_approvals: 1,
            max_revision_cycles: 3,
            profiles: vec![TaskBoardReviewerProfile::default()],
            overrides: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardRepositoryAutomationConfig {
    pub repository: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub workflows: Vec<TaskBoardOrchestratorWorkflow>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_host_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_checkout_path: Option<String>,
    // Publication conventions this repository does not share with the rest.
    // `None` inherits the global value; `Some` replaces it whole, so a
    // repository can drop a reviewer set rather than only add to one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requested_reviewers: Option<GitHubRequestedReviewers>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protected_paths: Option<Vec<ProtectedPathRule>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub labels: Option<GitHubAutomationLabels>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled_automations: Option<GitHubAutomationToggles>,
}

impl Default for TaskBoardRepositoryAutomationConfig {
    fn default() -> Self {
        Self {
            repository: String::new(),
            enabled: true,
            workflows: Vec::new(),
            preferred_host_id: None,
            execution_checkout_path: None,
            requested_reviewers: None,
            protected_paths: None,
            labels: None,
            enabled_automations: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardExecutionHostConfig {
    pub host_id: String,
    pub endpoint: String,
    /// Canonical `sha256/<base64>` SPKI continuity pin emitted by remote pairing.
    pub certificate_fingerprint: String,
    pub credential_reference: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardLocalExecutionRepositoryConfig {
    pub repository: String,
    pub checkout_path: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardLocalExecutionHostConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub host_id: String,
    #[serde(default)]
    pub capacity: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repositories: Vec<TaskBoardLocalExecutionRepositoryConfig>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub runtimes: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub capabilities: Vec<TaskBoardPhaseCapabilityProfile>,
}

const fn default_true() -> bool {
    true
}
