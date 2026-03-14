use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;

/// Active authoring session state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoringSession {
    pub repo_root: String,
    pub feature: String,
    pub mode: String,
    pub suite_name: String,
    pub suite_dir: String,
    pub updated_at: String,
}

impl AuthoringSession {
    #[must_use]
    pub fn suite_path(&self) -> PathBuf {
        PathBuf::from(&self.suite_dir).join("suite.md")
    }
}

/// File inventory payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileInventory {
    pub scoped_files: Vec<String>,
}

/// A coverage group.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoverageGroup {
    pub group_id: String,
    pub title: String,
    #[serde(default)]
    pub has_material: bool,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source_files: Vec<String>,
}

/// Coverage summary result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoverageSummary {
    pub summary: String,
    #[serde(default)]
    pub groups: Vec<CoverageGroup>,
}

/// A variant signal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VariantSignal {
    pub signal_id: String,
    pub strength: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source_files: Vec<String>,
    #[serde(default)]
    pub suggested_groups: Vec<String>,
}

/// Variant summary result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VariantSummary {
    pub summary: String,
    #[serde(default)]
    pub signals: Vec<VariantSignal>,
}

/// A schema fact.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SchemaFact {
    pub resource: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source_files: Vec<String>,
    #[serde(default)]
    pub required_fields: Vec<String>,
}

/// Schema summary result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SchemaSummary {
    pub summary: String,
    #[serde(default)]
    pub facts: Vec<SchemaFact>,
}

/// A proposal group.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProposalGroup {
    pub group_id: String,
    pub title: String,
    #[serde(default)]
    pub included: bool,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source_refs: Vec<String>,
}

/// Proposal summary result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProposalSummary {
    pub summary: String,
    #[serde(default)]
    pub suite_name: Option<String>,
    #[serde(default)]
    pub suite_dir: Option<String>,
    #[serde(default)]
    pub run_command: Option<String>,
    #[serde(default)]
    pub groups: Vec<ProposalGroup>,
    #[serde(default)]
    pub required_dependencies: Vec<String>,
    #[serde(default)]
    pub skipped_groups: Vec<String>,
}

/// Draft edit request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DraftEditRequest {
    pub summary: String,
    #[serde(default)]
    pub targets: Vec<String>,
}

/// Load the current authoring session from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn load_authoring_session() -> Result<Option<AuthoringSession>, CliError> {
    todo!()
}

/// Save an authoring session to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn save_authoring_session(_session: &AuthoringSession) -> Result<AuthoringSession, CliError> {
    todo!()
}

/// Require an active authoring session.
///
/// # Errors
/// Returns `CliError` if no session is active.
pub fn require_authoring_session() -> Result<AuthoringSession, CliError> {
    todo!()
}

/// Begin a new authoring session.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn begin_authoring_session(
    _repo_root: &Path,
    _feature: &str,
    _mode: &str,
    _suite_dir: &Path,
    _suite_name: &str,
) -> Result<AuthoringSession, CliError> {
    todo!()
}

/// Workspace directory for authoring artifacts.
#[must_use]
pub fn authoring_workspace_dir() -> PathBuf {
    todo!()
}

#[cfg(test)]
mod tests {}
