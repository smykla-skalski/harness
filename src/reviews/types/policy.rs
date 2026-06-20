use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::task_board::github::GitHubMergeMethod;

use super::super::logic::default_reviews_policy_workflow_id;
use super::ReviewTarget;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicySubject {
    pub repository: String,
    pub pull_request_number: u64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewsPolicyTrigger {
    Background,
    Event,
    #[default]
    Manual,
    ManualNudge,
    Timer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewsPolicyRunStatus {
    Completed,
    Failed,
    Running,
    Waiting,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewsPolicyStepType {
    Action,
    Wait,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyWait {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub event_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyPreviewStep {
    pub step_type: ReviewsPolicyStepType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_on: Option<ReviewsPolicyWait>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyPreviewRequest {
    #[serde(default = "default_reviews_policy_workflow_id")]
    pub workflow_id: String,
    pub target: ReviewTarget,
    #[serde(default)]
    pub method: GitHubMergeMethod,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyPreviewResponse {
    pub workflow_id: String,
    pub subject: ReviewsPolicySubject,
    pub eligible: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<ReviewsPolicyPreviewStep>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyRunStartRequest {
    #[serde(default = "default_reviews_policy_workflow_id")]
    pub workflow_id: String,
    pub target: ReviewTarget,
    #[serde(default)]
    pub method: GitHubMergeMethod,
    #[serde(default)]
    pub trigger: ReviewsPolicyTrigger,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyRunStep {
    pub step_type: ReviewsPolicyStepType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_on: Option<ReviewsPolicyWait>,
    pub recorded_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyRunResponse {
    pub workflow_id: String,
    pub run_id: String,
    pub subject: ReviewsPolicySubject,
    pub trigger: ReviewsPolicyTrigger,
    pub status: ReviewsPolicyRunStatus,
    pub started_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_on: Option<ReviewsPolicyWait>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<ReviewsPolicyRunStep>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyStatusRequest {
    #[serde(default = "default_reviews_policy_workflow_id")]
    pub workflow_id: String,
    pub subject: ReviewsPolicySubject,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyStatusResponse {
    pub workflow_id: String,
    pub subject: ReviewsPolicySubject,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_run: Option<ReviewsPolicyRunResponse>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub recent_runs: Vec<ReviewsPolicyRunResponse>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyHistoryRequest {
    #[serde(default = "default_reviews_policy_workflow_id")]
    pub workflow_id: String,
    pub subject: ReviewsPolicySubject,
}

/// Aggregate status and trigger counts for the runs in a history response.
/// Mirrors the runtime metrics summary so the Monitor app can render totals
/// without re-deriving them from the run list.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyRunMetrics {
    pub total: usize,
    pub running: usize,
    pub waiting: usize,
    pub completed: usize,
    pub failed: usize,
    pub cancelled: usize,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub by_trigger: BTreeMap<String, usize>,
}

/// A single structured entry in a policy run timeline export, flattened from
/// the recorded step list across the response's runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyTimelineEntry {
    pub recorded_at: String,
    pub run_id: String,
    pub event: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyHistoryResponse {
    pub workflow_id: String,
    pub subject: ReviewsPolicySubject,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub runs: Vec<ReviewsPolicyRunResponse>,
    #[serde(default)]
    pub metrics: ReviewsPolicyRunMetrics,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub timeline: Vec<ReviewsPolicyTimelineEntry>,
}
