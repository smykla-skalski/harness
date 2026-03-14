use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;

/// A single helm value entry (key=value).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HelmValueEntry {
    pub key: String,
    pub value: serde_json::Value,
}

/// Suite frontmatter payload deserialized from suite.md YAML header.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SuiteFrontmatter {
    pub suite_id: String,
    pub feature: String,
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub profiles: Vec<String>,
    #[serde(default)]
    pub required_dependencies: Vec<String>,
    #[serde(default)]
    pub user_stories: Vec<String>,
    #[serde(default)]
    pub variant_decisions: Vec<String>,
    #[serde(default)]
    pub coverage_expectations: Vec<String>,
    #[serde(default)]
    pub baseline_files: Vec<String>,
    #[serde(default)]
    pub groups: Vec<String>,
    #[serde(default)]
    pub skipped_groups: Vec<String>,
    #[serde(default)]
    pub keep_clusters: bool,
}

/// A loaded suite specification with its source path.
#[derive(Debug, Clone)]
pub struct SuiteSpec {
    pub frontmatter: SuiteFrontmatter,
    pub path: PathBuf,
}

impl SuiteSpec {
    /// Load a suite spec from a markdown file.
    ///
    /// # Errors
    /// Returns `CliError` if the file is missing or frontmatter is invalid.
    pub fn from_markdown(_path: &Path) -> Result<Self, CliError> {
        todo!()
    }

    #[must_use]
    pub fn suite_dir(&self) -> &Path {
        self.path.parent().unwrap_or(Path::new("."))
    }
}

/// Group frontmatter payload from a group markdown file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GroupFrontmatter {
    pub group_id: String,
    pub story: String,
    #[serde(default)]
    pub capability: Option<String>,
    #[serde(default)]
    pub profiles: Vec<String>,
    #[serde(default)]
    pub preconditions: Vec<String>,
    #[serde(default)]
    pub success_criteria: Vec<String>,
    #[serde(default)]
    pub debug_checks: Vec<String>,
    #[serde(default)]
    pub artifacts: Vec<String>,
    #[serde(default)]
    pub variant_source: Option<String>,
    #[serde(default)]
    pub helm_values: HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub restart_namespaces: Vec<String>,
    #[serde(default)]
    pub expected_rejection_orders: Vec<i64>,
}

/// A loaded group specification with path and body.
#[derive(Debug, Clone)]
pub struct GroupSpec {
    pub frontmatter: GroupFrontmatter,
    pub path: PathBuf,
    pub body: String,
}

impl GroupSpec {
    /// Load a group spec from a markdown file.
    ///
    /// # Errors
    /// Returns `CliError` if the file is missing, frontmatter is invalid,
    /// or required sections are missing.
    pub fn from_markdown(_path: &Path) -> Result<Self, CliError> {
        todo!()
    }
}

/// Run report frontmatter.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunReportFrontmatter {
    pub run_id: String,
    pub suite_id: String,
    pub profile: String,
    pub overall_verdict: String,
    #[serde(default)]
    pub story_results: Vec<String>,
    #[serde(default)]
    pub debug_summary: Option<String>,
}

/// A loaded run report.
#[derive(Debug, Clone)]
pub struct RunReport {
    pub frontmatter: RunReportFrontmatter,
    pub path: PathBuf,
    pub body: String,
}

impl RunReport {
    /// Load from a markdown file.
    ///
    /// # Errors
    /// Returns `CliError` on failure.
    pub fn from_markdown(_path: &Path) -> Result<Self, CliError> {
        todo!()
    }

    /// Save the report to disk.
    ///
    /// # Errors
    /// Returns `CliError` on IO failure.
    pub fn save(&self) -> Result<(), CliError> {
        todo!()
    }
}

/// Counts of passed/failed/skipped groups in a run.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct RunCounts {
    pub passed: u32,
    pub failed: u32,
    pub skipped: u32,
}

/// Run status tracked in run-status.json.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunStatus {
    pub run_id: String,
    pub suite_id: String,
    pub profile: String,
    pub started_at: String,
    pub overall_verdict: String,
    #[serde(default)]
    pub completed_at: Option<String>,
    #[serde(default)]
    pub counts: RunCounts,
    #[serde(default)]
    pub executed_groups: Vec<serde_json::Value>,
    #[serde(default)]
    pub skipped_groups: Vec<String>,
    #[serde(default)]
    pub last_completed_group: Option<String>,
    #[serde(default)]
    pub last_state_capture: Option<String>,
    #[serde(default)]
    pub last_updated_utc: Option<String>,
    #[serde(default)]
    pub next_planned_group: Option<String>,
    #[serde(default)]
    pub notes: Vec<String>,
}

#[cfg(test)]
mod tests {}
