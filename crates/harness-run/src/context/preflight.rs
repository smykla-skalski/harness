use serde::{Deserialize, Serialize};

use super::{NodeCheckSnapshot, ToolCheckSnapshot};

/// Preflight artifact containing tool/node check results.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreflightArtifact {
    pub checked_at: String,
    #[serde(default)]
    pub prepared_suite_path: Option<String>,
    #[serde(default)]
    pub repo_root: Option<String>,
    #[serde(default)]
    pub tools: ToolCheckSnapshot,
    #[serde(default)]
    pub nodes: NodeCheckSnapshot,
}
