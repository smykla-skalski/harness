use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;

/// SHA256 fingerprint of a file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileFingerprint {
    pub label: String,
    pub path: String,
    pub exists: bool,
    #[serde(default)]
    pub size: Option<u64>,
    #[serde(default)]
    pub mtime_ns: Option<u64>,
    #[serde(default)]
    pub sha256: Option<String>,
}

/// Runner handoff state for compaction.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunnerHandoff {
    pub run_dir: String,
    pub run_id: String,
    pub suite_id: String,
    pub profile: String,
    #[serde(default)]
    pub overall_verdict: Option<String>,
    #[serde(default)]
    pub runner_phase: Option<String>,
    #[serde(default)]
    pub next_planned_group: Option<String>,
    #[serde(default)]
    pub notes: Vec<String>,
}

/// Authoring handoff state for compaction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoringHandoff {
    #[serde(default)]
    pub feature: Option<String>,
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub suite_name: Option<String>,
    #[serde(default)]
    pub suite_dir: Option<String>,
    #[serde(default)]
    pub author_phase: Option<String>,
}

/// Full compact handoff payload.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompactHandoff {
    pub version: u32,
    pub project_dir: String,
    pub created_at: String,
    pub status: String,
    #[serde(default)]
    pub source_session_scope: Option<String>,
    #[serde(default)]
    pub source_session_id: Option<String>,
    #[serde(default)]
    pub transcript_path: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub trigger: Option<String>,
    #[serde(default)]
    pub custom_instructions: Option<String>,
    #[serde(default)]
    pub consumed_at: Option<String>,
    #[serde(default)]
    pub runner: Option<RunnerHandoff>,
    #[serde(default)]
    pub authoring: Option<AuthoringHandoff>,
    #[serde(default)]
    pub fingerprints: Vec<FileFingerprint>,
}

/// Path to the latest compact handoff file.
#[must_use]
pub fn compact_latest_path(project_dir: &Path) -> PathBuf {
    compact_project_dir(project_dir).join("latest.json")
}

/// Compact directory for a project.
#[must_use]
pub fn compact_project_dir(_project_dir: &Path) -> PathBuf {
    todo!()
}

/// Build a compact handoff from the current state.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn build_compact_handoff(_project_dir: &Path) -> Result<CompactHandoff, CliError> {
    todo!()
}

/// Save a compact handoff.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn save_compact_handoff(
    _project_dir: &Path,
    _handoff: &CompactHandoff,
) -> Result<CompactHandoff, CliError> {
    todo!()
}

/// Load the latest compact handoff.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn load_latest_compact_handoff(
    _project_dir: &Path,
) -> Result<Option<CompactHandoff>, CliError> {
    todo!()
}

/// Render the hydration context for a compact handoff.
#[must_use]
pub fn render_hydration_context(_handoff: &CompactHandoff, _diverged_paths: &[String]) -> String {
    todo!()
}

#[cfg(test)]
mod tests {}
