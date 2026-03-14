use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::cluster::ClusterSpec;
use crate::errors::CliError;
use crate::prepared_suite::PreparedSuiteArtifact;
use crate::schema::RunStatus;

/// Filesystem layout for a single run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunLayout {
    pub run_root: String,
    pub run_id: String,
}

impl RunLayout {
    #[must_use]
    pub fn run_dir(&self) -> PathBuf {
        PathBuf::from(&self.run_root).join(&self.run_id)
    }

    #[must_use]
    pub fn artifacts_dir(&self) -> PathBuf {
        self.run_dir().join("artifacts")
    }

    #[must_use]
    pub fn commands_dir(&self) -> PathBuf {
        self.run_dir().join("commands")
    }

    #[must_use]
    pub fn state_dir(&self) -> PathBuf {
        self.run_dir().join("state")
    }

    #[must_use]
    pub fn manifests_dir(&self) -> PathBuf {
        self.run_dir().join("manifests")
    }

    #[must_use]
    pub fn metadata_path(&self) -> PathBuf {
        self.run_dir().join("run-metadata.json")
    }

    #[must_use]
    pub fn status_path(&self) -> PathBuf {
        self.run_dir().join("run-status.json")
    }

    #[must_use]
    pub fn report_path(&self) -> PathBuf {
        self.run_dir().join("run-report.md")
    }

    #[must_use]
    pub fn prepared_suite_path(&self) -> PathBuf {
        self.run_dir().join("prepared-suite.json")
    }

    /// Create required subdirectories.
    ///
    /// # Errors
    /// Returns IO error on failure.
    pub fn ensure_dirs(&self) -> std::io::Result<()> {
        todo!()
    }

    /// Build from a run directory path.
    #[must_use]
    pub fn from_run_dir(run_dir: &Path) -> Self {
        let run_id = run_dir
            .file_name()
            .map_or_else(String::new, |n| n.to_string_lossy().to_string());
        let run_root = run_dir
            .parent()
            .map_or_else(|| ".".to_string(), |p| p.to_string_lossy().to_string());
        Self { run_root, run_id }
    }
}

/// Immutable metadata for a run, stored in run-metadata.json.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunMetadata {
    pub run_id: String,
    pub suite_id: String,
    pub suite_path: String,
    pub suite_dir: String,
    pub profile: String,
    pub repo_root: String,
    #[serde(default)]
    pub keep_clusters: bool,
    pub created_at: String,
    #[serde(default)]
    pub user_stories: Vec<String>,
    #[serde(default)]
    pub required_dependencies: Vec<String>,
}

/// Lookup key for resolving a run directory.
#[derive(Debug, Clone, Default)]
pub struct RunLookup {
    pub run_dir: Option<String>,
    pub run_id: Option<String>,
    pub run_root: Option<String>,
}

/// Environment variables for command execution within a run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandEnv {
    pub profile: String,
    pub repo_root: String,
    pub run_dir: String,
    pub run_id: String,
    pub run_root: String,
    pub suite_dir: String,
    pub suite_id: String,
    pub suite_path: String,
    #[serde(default)]
    pub kubeconfig: Option<String>,
}

impl CommandEnv {
    #[must_use]
    pub fn to_env_dict(&self) -> HashMap<String, String> {
        todo!()
    }
}

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

/// Preflight artifact containing tool/node check results.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreflightArtifact {
    pub checked_at: String,
    #[serde(default)]
    pub prepared_suite_path: Option<String>,
    #[serde(default)]
    pub repo_root: Option<String>,
    #[serde(default)]
    pub tools: serde_json::Value,
    #[serde(default)]
    pub nodes: serde_json::Value,
}

/// Update fields for the current run context.
#[derive(Debug, Clone, Default)]
pub struct CurrentRunUpdate {
    pub cluster: Option<ClusterSpec>,
    pub prepared_suite_path: Option<String>,
    pub preflight_artifact_path: Option<String>,
    pub run_report_path: Option<String>,
}

/// Persisted current run record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CurrentRunRecord {
    pub layout: RunLayout,
    #[serde(default)]
    pub profile: Option<String>,
    #[serde(default)]
    pub repo_root: Option<String>,
    #[serde(default)]
    pub suite_dir: Option<String>,
    #[serde(default)]
    pub suite_id: Option<String>,
    #[serde(default)]
    pub suite_path: Option<String>,
    #[serde(default)]
    pub cluster: Option<ClusterSpec>,
    #[serde(default)]
    pub keep_clusters: bool,
    #[serde(default)]
    pub user_stories: Vec<String>,
    #[serde(default)]
    pub required_dependencies: Vec<String>,
}

/// Full run context combining layout, metadata, status, cluster, etc.
#[derive(Debug)]
pub struct RunContext {
    pub layout: RunLayout,
    pub metadata: RunMetadata,
    pub status: Option<RunStatus>,
    pub cluster: Option<ClusterSpec>,
    pub prepared_suite: Option<PreparedSuiteArtifact>,
    pub preflight: Option<PreflightArtifact>,
}

impl RunContext {
    /// Load from a run directory.
    ///
    /// # Errors
    /// Returns `CliError` if required files are missing.
    pub fn from_run_dir(_run_dir: &Path) -> Result<Self, CliError> {
        todo!()
    }

    /// Load from the current session context.
    ///
    /// # Errors
    /// Returns `CliError` on failure.
    pub fn from_current() -> Result<Option<Self>, CliError> {
        todo!()
    }
}

#[cfg(test)]
mod tests {}
