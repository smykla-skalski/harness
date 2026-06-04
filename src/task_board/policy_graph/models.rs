use serde::{Deserialize, Serialize};

use super::defaults;
use super::{PolicyGraphDecision, PolicyReasonCode};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphAutomationBinding {
    #[serde(default = "defaults::default_automation_enabled")]
    pub is_enabled: bool,
    pub event_source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<i32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub content_kinds: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub preprocessors: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub postprocessors: Vec<String>,
    #[serde(default = "defaults::default_automation_source_app_mode")]
    pub source_app_mode: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub allowed_bundle_identifiers: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub denied_bundle_identifiers: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ocr_configuration: Option<PolicyGraphOCRConfiguration>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_pull_request_extraction: Option<PolicyGraphReviewPullRequestExtraction>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphOCRConfiguration {
    #[serde(default = "defaults::default_ocr_recognition_level")]
    pub recognition_level: String,
    #[serde(default = "defaults::default_true")]
    pub automatically_detects_language: bool,
    #[serde(default = "defaults::default_true")]
    pub uses_language_correction: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphReviewPullRequestExtraction {
    #[serde(default = "defaults::default_review_repository_mode")]
    pub repository_mode: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_repositories: Vec<String>,
    #[serde(default = "defaults::default_true")]
    pub number_memory_enabled: bool,
    #[serde(default = "defaults::default_review_result_scope")]
    pub result_scope: String,
    #[serde(default = "defaults::default_review_failure_signal_mode")]
    pub failure_signal_mode: String,
    #[serde(default = "defaults::default_review_output_format")]
    pub output_format: String,
    #[serde(default = "defaults::default_true")]
    pub auto_copy: bool,
    #[serde(default = "defaults::default_true")]
    pub show_sheet: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyWorkflowEntry {
    pub workflow_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyActionStep {
    pub action_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyWaitStep {
    pub wait: PolicyWaitCondition,
    pub resume_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PolicyWaitCondition {
    Timer { duration_seconds: u64 },
    Event { event_key: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyRuntimeBoundary {
    pub node_id: String,
    pub resume_key: String,
    pub wait: PolicyWaitCondition,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyEventWait {
    pub event_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyHandoffStep {
    pub handoff_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyFinishNode {
    pub decision: PolicyGraphDecision,
    pub reason_code: PolicyReasonCode,
}
