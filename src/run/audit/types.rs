use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditEntry {
    pub timestamp: String,
    pub tool_name: String,
    pub tool_input: String,
    pub output_summary: String,
    pub content_hash: String,
    pub artifact_path: String,
    pub phase: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditPhaseContext {
    pub phase: String,
    pub group_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditAppendRequest {
    pub run_dir: PathBuf,
    pub tool_name: String,
    pub tool_input: String,
    pub full_output: String,
    pub phase: String,
    pub group_id: Option<String>,
}

impl AuditPhaseContext {
    #[must_use]
    pub fn new(phase: String, group_id: Option<String>) -> Self {
        Self { phase, group_id }
    }
}
