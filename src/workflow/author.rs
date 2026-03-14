use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;

/// Author approval mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalMode {
    Interactive,
    Bypass,
}

/// Author workflow phases.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum AuthorPhase {
    Discovery,
    PrewriteReview,
    Writing,
    PostwriteReview,
    Complete,
    Cancelled,
}

/// Review gate type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewGate {
    Prewrite,
    Postwrite,
    Copy,
}

/// Answer to a review gate prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AuthorAnswer {
    #[serde(rename = "Approve proposal")]
    ApproveProposal,
    #[serde(rename = "Request changes")]
    RequestChanges,
    #[serde(rename = "Cancel")]
    Cancel,
    #[serde(rename = "Approve suite")]
    ApproveSuite,
    #[serde(rename = "Copy command")]
    CopyCommand,
    #[serde(rename = "Skip")]
    Skip,
}

/// Session info within author state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorSessionInfo {
    #[serde(default)]
    pub repo_root: Option<String>,
    #[serde(default)]
    pub feature: Option<String>,
    #[serde(default)]
    pub suite_name: Option<String>,
    #[serde(default)]
    pub suite_dir: Option<String>,
}

/// Review sub-state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorReviewState {
    #[serde(default)]
    pub gate: Option<ReviewGate>,
    #[serde(default)]
    pub awaiting_answer: bool,
    #[serde(default)]
    pub round: u32,
    #[serde(default)]
    pub last_answer: Option<AuthorAnswer>,
}

/// Draft sub-state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorDraftState {
    #[serde(default)]
    pub suite_tree_written: bool,
    #[serde(default)]
    pub written_paths: Vec<String>,
}

/// Full author workflow state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorWorkflowState {
    pub schema_version: u32,
    pub mode: ApprovalMode,
    pub phase: AuthorPhase,
    pub session: AuthorSessionInfo,
    pub review: AuthorReviewState,
    pub draft: AuthorDraftState,
    pub updated_at: String,
    pub transition_count: u32,
    #[serde(default)]
    pub last_event: Option<String>,
}

/// Path to the author state file.
#[must_use]
pub fn author_state_path() -> PathBuf {
    todo!()
}

/// Read author state from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn read_author_state() -> Result<Option<AuthorWorkflowState>, CliError> {
    todo!()
}

/// Write author state to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_author_state(_state: &AuthorWorkflowState) -> Result<AuthorWorkflowState, CliError> {
    todo!()
}

/// Check if writing is allowed in the current state.
#[must_use]
pub fn can_write(_state: &AuthorWorkflowState) -> (bool, Option<&'static str>) {
    todo!()
}

/// Check if a review gate can be requested.
#[must_use]
pub fn can_request_gate(
    _state: &AuthorWorkflowState,
    _gate: ReviewGate,
) -> (bool, Option<&'static str>) {
    todo!()
}

/// Check if the author flow can be stopped.
#[must_use]
pub fn can_stop(_state: &AuthorWorkflowState) -> (bool, Option<&'static str>) {
    todo!()
}

/// Get the next action hint based on author state.
#[must_use]
pub fn next_action(_state: Option<&AuthorWorkflowState>) -> String {
    todo!()
}

/// Check if a path is allowed for suite-author writes.
#[must_use]
pub fn suite_author_path_allowed(_path: &Path, _suite_dir: &Path) -> bool {
    todo!()
}

#[cfg(test)]
mod tests {}
