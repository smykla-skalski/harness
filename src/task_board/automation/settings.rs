use serde::{Deserialize, Serialize};

use crate::task_board::{AgentMode, TaskBoardOrchestratorWorkflow};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardReviewerRule {
    pub workflow: TaskBoardOrchestratorWorkflow,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    pub reviewer_count: u32,
    pub required_approvals: u32,
    pub profiles: Vec<TaskBoardReviewerProfile>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardRepositoryAutomationConfig {
    pub repository: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub workflows: Vec<TaskBoardOrchestratorWorkflow>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_host_id: Option<String>,
}

impl Default for TaskBoardRepositoryAutomationConfig {
    fn default() -> Self {
        Self {
            repository: String::new(),
            enabled: true,
            workflows: Vec::new(),
            preferred_host_id: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardExecutionHostConfig {
    pub host_id: String,
    pub endpoint: String,
    pub certificate_fingerprint: String,
    pub credential_reference: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

const fn default_true() -> bool {
    true
}
