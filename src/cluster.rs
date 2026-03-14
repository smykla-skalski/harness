use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// A member of a cluster deployment (zone or global).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClusterMember {
    pub name: String,
    pub role: String,
    #[serde(default)]
    pub kubeconfig: Option<String>,
    #[serde(default)]
    pub zone_name: Option<String>,
}

/// A helm setting (key=value for --set flags).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HelmSetting {
    pub key: String,
    pub value: String,
}

impl HelmSetting {
    /// Parse from a "key=value" CLI argument.
    ///
    /// # Errors
    /// Returns an error if the format is invalid.
    pub fn from_cli_arg(_raw: &str) -> Result<Self, String> {
        todo!()
    }

    #[must_use]
    pub fn to_cli_arg(&self) -> String {
        format!("{}={}", self.key, self.value)
    }
}

/// Full cluster specification describing a deployment topology.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClusterSpec {
    pub mode: String,
    #[serde(default)]
    pub members: Vec<ClusterMember>,
    #[serde(default)]
    pub mode_args: Vec<String>,
    #[serde(default)]
    pub helm_settings: Vec<HelmSetting>,
    #[serde(default)]
    pub restart_namespaces: Vec<String>,
    #[serde(default)]
    pub repo_root: Option<PathBuf>,
}

/// Current deploy state, written to current-deploy.json.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CurrentDeployPayload {
    pub mode: String,
    pub updated_at: String,
    #[serde(default)]
    pub mode_args: Vec<String>,
    #[serde(default)]
    pub helm_settings: Vec<HelmSetting>,
    #[serde(default)]
    pub restart_namespaces: Vec<String>,
}

/// Cluster record payload for serialization.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClusterRecordPayload {
    pub mode: String,
    #[serde(default)]
    pub mode_args: Vec<String>,
    #[serde(default)]
    pub members: Vec<ClusterMember>,
    #[serde(default)]
    pub helm_settings: Vec<HelmSetting>,
    #[serde(default)]
    pub restart_namespaces: Vec<String>,
    #[serde(default)]
    pub repo_root: Option<String>,
}

#[cfg(test)]
mod tests {}
