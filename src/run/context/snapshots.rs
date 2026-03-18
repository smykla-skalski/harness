use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Snapshot of a command artifact for state tracking.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ArtifactSnapshot {
    pub kind: String,
    #[serde(default)]
    pub exists: bool,
    #[serde(default)]
    pub row_count: Option<u32>,
    #[serde(default)]
    pub files: Vec<String>,
}

/// Snapshot of tool availability during preflight.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolCheckRecord {
    pub name: String,
    #[serde(default)]
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// Snapshot of node or cluster-member reachability during preflight.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NodeCheckRecord {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reachable: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// Typed wrapper for tool check results with a bounded escape hatch.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ToolCheckSnapshot {
    #[serde(default)]
    pub items: Vec<ToolCheckRecord>,
    #[serde(default, flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

/// Typed wrapper for node check results with a bounded escape hatch.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct NodeCheckSnapshot {
    #[serde(default)]
    pub items: Vec<NodeCheckRecord>,
    #[serde(default, flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}
