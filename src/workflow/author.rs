use std::env;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind, cow};

/// Author approval mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
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

impl fmt::Display for AuthorPhase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Discovery => "discovery",
            Self::PrewriteReview => "prewrite_review",
            Self::Writing => "writing",
            Self::PostwriteReview => "postwrite_review",
            Self::Complete => "complete",
            Self::Cancelled => "cancelled",
        })
    }
}

/// Review gate type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
#[serde(rename_all = "snake_case")]
pub enum ReviewGate {
    Prewrite,
    Postwrite,
    Copy,
}

#[non_exhaustive]
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo_root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub feature: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_dir: Option<String>,
}

impl AuthorSessionInfo {
    #[must_use]
    pub fn suite_path(&self) -> Option<PathBuf> {
        self.suite_dir.as_ref().map(PathBuf::from)
    }
}

/// Review sub-state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorReviewState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gate: Option<ReviewGate>,
    #[serde(default)]
    pub awaiting_answer: bool,
    #[serde(default)]
    pub round: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event: Option<String>,
}

impl AuthorWorkflowState {
    #[must_use]
    pub fn has_written_suite(&self) -> bool {
        self.draft.suite_tree_written
    }

    #[must_use]
    pub fn suite_dir(&self) -> Option<&str> {
        self.session.suite_dir.as_deref()
    }

    #[must_use]
    pub fn suite_path(&self) -> Option<PathBuf> {
        self.session.suite_path()
    }
}

/// Path to the author state file.
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn author_state_path() -> Result<PathBuf, CliError> {
    let cwd = env::current_dir().map_err(|e| -> CliError {
        CliErrorKind::workflow_io(cow!("failed to determine current directory: {e}")).into()
    })?;
    Ok(cwd.join(".harness").join("suite-author-state.json"))
}

/// Read author state from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn read_author_state() -> Result<Option<AuthorWorkflowState>, CliError> {
    let path = author_state_path()?;
    if !path.exists() {
        return Ok(None);
    }
    let contents = fs::read_to_string(&path).map_err(|e| -> CliError {
        CliErrorKind::workflow_io(cow!("failed to read {}: {e}", path.display())).into()
    })?;
    let state: AuthorWorkflowState = serde_json::from_str(&contents).map_err(|e| -> CliError {
        CliErrorKind::workflow_parse(cow!("failed to parse author state: {e}")).into()
    })?;
    Ok(Some(state))
}

/// Write author state to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_author_state(state: &AuthorWorkflowState) -> Result<(), CliError> {
    let path = author_state_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| -> CliError {
            CliErrorKind::workflow_io(cow!("failed to create directory {}: {e}", parent.display()))
                .into()
        })?;
    }
    let json = serde_json::to_string_pretty(state).map_err(|e| -> CliError {
        CliErrorKind::workflow_serialize(cow!("failed to serialize author state: {e}")).into()
    })?;
    let tmp_path = path.with_extension("json.tmp");
    fs::write(&tmp_path, &json).map_err(|e| -> CliError {
        CliErrorKind::workflow_io(cow!("failed to write {}: {e}", tmp_path.display())).into()
    })?;
    fs::rename(&tmp_path, &path).map_err(|e| -> CliError {
        CliErrorKind::workflow_io(cow!("failed to rename to {}: {e}", path.display())).into()
    })?;
    Ok(())
}

/// Check if writing is allowed in the current state.
///
/// # Errors
/// Returns a static reason string when writing is not allowed.
pub fn can_write(state: &AuthorWorkflowState) -> Result<(), &'static str> {
    if state.mode == ApprovalMode::Bypass {
        return Ok(());
    }
    match state.phase {
        AuthorPhase::Writing => Ok(()),
        AuthorPhase::PrewriteReview => {
            Err("wait for the current pre-write approval answer before writing suite files")
        }
        AuthorPhase::PostwriteReview => {
            Err("wait for the current post-write approval answer before editing the saved suite")
        }
        AuthorPhase::Complete => {
            Err("the saved suite is already approved; request changes before editing it again")
        }
        AuthorPhase::Cancelled => {
            Err("the suite-author flow was cancelled; restart authoring before writing again")
        }
        AuthorPhase::Discovery => {
            Err("suite-author is still collecting context before the first review gate")
        }
    }
}

/// Check if a review gate can be requested.
///
/// # Errors
/// Returns a static reason string when the gate cannot be requested.
pub fn can_request_gate(state: &AuthorWorkflowState, gate: ReviewGate) -> Result<(), &'static str> {
    if state.mode == ApprovalMode::Bypass {
        return Err("bypass mode forbids canonical review prompts");
    }
    match gate {
        ReviewGate::Prewrite => {
            if state.phase == AuthorPhase::PrewriteReview {
                Ok(())
            } else {
                Err("pre-write approval can only run while the proposal is still pending")
            }
        }
        ReviewGate::Postwrite => {
            if !state.has_written_suite() {
                return Err("ask post-write approval before stopping after suite writes");
            }
            if state.phase == AuthorPhase::Writing {
                Ok(())
            } else {
                Err("post-write approval is only valid after initial writes or an edit round")
            }
        }
        ReviewGate::Copy => {
            if state.phase == AuthorPhase::Complete {
                Ok(())
            } else {
                Err("copy prompt is only valid after the saved suite is approved")
            }
        }
    }
}

/// Check if the author flow can be stopped.
///
/// # Errors
/// Returns a static reason string when stopping is not allowed.
pub fn can_stop(state: &AuthorWorkflowState) -> Result<(), &'static str> {
    if state.mode == ApprovalMode::Bypass {
        return Ok(());
    }
    match state.phase {
        AuthorPhase::Writing => Err("ask the post-write approval gate before stopping"),
        AuthorPhase::PostwriteReview => {
            Err("wait for the current post-write approval answer before stopping")
        }
        _ => Ok(()),
    }
}

/// Next action for an author workflow state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthorNextAction {
    ReloadState,
    ContinueBypass,
    ResumeDiscovery,
    ResumePrewriteReview,
    ApplyEditRound,
    ContinueInitialWrite,
    ResumePostwriteReview,
    Stopped,
    OfferCopyGate,
}

impl fmt::Display for AuthorNextAction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::ReloadState => {
                "Reload the saved suite-author state before continuing."
            }
            Self::ContinueBypass => {
                "Continue suite-author in bypass mode using the saved authoring payloads."
            }
            Self::ResumeDiscovery => {
                "Resume discovery and proposal preparation before reopening review."
            }
            Self::ResumePrewriteReview => {
                "Resume the pre-write review loop and ask the pre-write gate question before writing suite files."
            }
            Self::ApplyEditRound => {
                "Apply the current edit round, then reopen the post-write review gate."
            }
            Self::ContinueInitialWrite => {
                "Continue the initial suite write phase from the saved proposal."
            }
            Self::ResumePostwriteReview => {
                "Resume the post-write review loop and ask the post-write gate question before stopping."
            }
            Self::Stopped => {
                "The suite-author flow was cancelled. Do not write more files unless restarted."
            }
            Self::OfferCopyGate => {
                "The suite is approved. Offer the copy gate or stop the skill."
            }
        })
    }
}

/// Get the next action hint based on author state.
#[must_use]
pub fn next_action(state: Option<&AuthorWorkflowState>) -> AuthorNextAction {
    let Some(state) = state else {
        return AuthorNextAction::ReloadState;
    };
    if state.mode == ApprovalMode::Bypass {
        return AuthorNextAction::ContinueBypass;
    }
    match state.phase {
        AuthorPhase::Discovery => AuthorNextAction::ResumeDiscovery,
        AuthorPhase::PrewriteReview => AuthorNextAction::ResumePrewriteReview,
        AuthorPhase::Writing => {
            if state.has_written_suite() {
                AuthorNextAction::ApplyEditRound
            } else {
                AuthorNextAction::ContinueInitialWrite
            }
        }
        AuthorPhase::PostwriteReview => AuthorNextAction::ResumePostwriteReview,
        AuthorPhase::Cancelled => AuthorNextAction::Stopped,
        AuthorPhase::Complete => AuthorNextAction::OfferCopyGate,
    }
}

/// Check if a path is allowed for suite-author writes.
#[must_use]
pub fn suite_author_path_allowed(path: &Path, suite_dir: &Path) -> bool {
    if path == suite_dir.join("suite.md") {
        return true;
    }
    if path.starts_with(suite_dir.join("groups")) {
        return true;
    }
    path.starts_with(suite_dir.join("baseline"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_state(phase: AuthorPhase, mode: ApprovalMode) -> AuthorWorkflowState {
        AuthorWorkflowState {
            schema_version: 1,
            mode,
            phase,
            session: AuthorSessionInfo {
                repo_root: None,
                feature: None,
                suite_name: None,
                suite_dir: Some("/tmp/suite".to_string()),
            },
            review: AuthorReviewState {
                gate: None,
                awaiting_answer: false,
                round: 0,
                last_answer: None,
            },
            draft: AuthorDraftState {
                suite_tree_written: false,
                written_paths: vec![],
            },
            updated_at: "2025-01-01T00:00:00Z".to_string(),
            transition_count: 0,
            last_event: None,
        }
    }

    #[test]
    fn author_phase_display() {
        let cases = [
            (AuthorPhase::Discovery, "discovery"),
            (AuthorPhase::PrewriteReview, "prewrite_review"),
            (AuthorPhase::Writing, "writing"),
            (AuthorPhase::PostwriteReview, "postwrite_review"),
            (AuthorPhase::Complete, "complete"),
            (AuthorPhase::Cancelled, "cancelled"),
        ];
        for (variant, expected) in cases {
            assert_eq!(variant.to_string(), expected);
        }
    }

    #[test]
    fn approval_mode_serialization() {
        let json = serde_json::to_value(ApprovalMode::Interactive).unwrap();
        assert_eq!(json, "interactive");
        let json = serde_json::to_value(ApprovalMode::Bypass).unwrap();
        assert_eq!(json, "bypass");
    }

    #[test]
    fn author_phase_serialization() {
        let cases = [
            (AuthorPhase::Discovery, "discovery"),
            (AuthorPhase::PrewriteReview, "prewrite_review"),
            (AuthorPhase::Writing, "writing"),
            (AuthorPhase::PostwriteReview, "postwrite_review"),
            (AuthorPhase::Complete, "complete"),
            (AuthorPhase::Cancelled, "cancelled"),
        ];
        for (variant, expected) in cases {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn review_gate_serialization() {
        for (variant, expected) in [
            (ReviewGate::Prewrite, "prewrite"),
            (ReviewGate::Postwrite, "postwrite"),
            (ReviewGate::Copy, "copy"),
        ] {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn author_answer_serialization() {
        let cases = [
            (AuthorAnswer::ApproveProposal, "Approve proposal"),
            (AuthorAnswer::RequestChanges, "Request changes"),
            (AuthorAnswer::Cancel, "Cancel"),
            (AuthorAnswer::ApproveSuite, "Approve suite"),
            (AuthorAnswer::CopyCommand, "Copy command"),
            (AuthorAnswer::Skip, "Skip"),
        ];
        for (variant, expected) in cases {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn full_state_serialization_round_trip() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        let json = serde_json::to_value(&state).unwrap();
        let loaded: AuthorWorkflowState = serde_json::from_value(json).unwrap();
        assert_eq!(loaded, state);
    }

    #[test]
    fn can_write_bypass_always_allows() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Bypass);
        assert!(can_write(&state).is_ok());
    }

    #[test]
    fn can_write_writing_phase_allows() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert!(can_write(&state).is_ok());
    }

    #[test]
    fn can_write_discovery_denies() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Interactive);
        assert!(can_write(&state).is_err());
    }

    #[test]
    fn can_write_prewrite_review_denies() {
        let state = make_state(AuthorPhase::PrewriteReview, ApprovalMode::Interactive);
        assert!(can_write(&state).unwrap_err().contains("pre-write"));
    }

    #[test]
    fn can_write_postwrite_review_denies() {
        let state = make_state(AuthorPhase::PostwriteReview, ApprovalMode::Interactive);
        assert!(can_write(&state).unwrap_err().contains("post-write"));
    }

    #[test]
    fn can_write_complete_denies() {
        let state = make_state(AuthorPhase::Complete, ApprovalMode::Interactive);
        assert!(can_write(&state).unwrap_err().contains("approved"));
    }

    #[test]
    fn can_write_cancelled_denies() {
        let state = make_state(AuthorPhase::Cancelled, ApprovalMode::Interactive);
        assert!(can_write(&state).unwrap_err().contains("cancelled"));
    }

    #[test]
    fn can_request_gate_bypass_denies() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Bypass);
        assert!(
            can_request_gate(&state, ReviewGate::Postwrite)
                .unwrap_err()
                .contains("bypass")
        );
    }

    #[test]
    fn can_request_prewrite_gate_in_prewrite_review() {
        let state = make_state(AuthorPhase::PrewriteReview, ApprovalMode::Interactive);
        assert!(can_request_gate(&state, ReviewGate::Prewrite).is_ok());
    }

    #[test]
    fn can_request_prewrite_gate_wrong_phase() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert!(can_request_gate(&state, ReviewGate::Prewrite).is_err());
    }

    #[test]
    fn can_request_postwrite_gate_after_writing() {
        let mut state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        state.draft.suite_tree_written = true;
        assert!(can_request_gate(&state, ReviewGate::Postwrite).is_ok());
    }

    #[test]
    fn can_request_postwrite_gate_without_writes_denies() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert!(can_request_gate(&state, ReviewGate::Postwrite).is_err());
    }

    #[test]
    fn can_request_copy_gate_in_complete() {
        let state = make_state(AuthorPhase::Complete, ApprovalMode::Interactive);
        assert!(can_request_gate(&state, ReviewGate::Copy).is_ok());
    }

    #[test]
    fn can_request_copy_gate_wrong_phase() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert!(can_request_gate(&state, ReviewGate::Copy).is_err());
    }

    #[test]
    fn can_stop_bypass_allows() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Bypass);
        assert!(can_stop(&state).is_ok());
    }

    #[test]
    fn can_stop_cancelled_allows() {
        let state = make_state(AuthorPhase::Cancelled, ApprovalMode::Interactive);
        assert!(can_stop(&state).is_ok());
    }

    #[test]
    fn can_stop_writing_denies() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert!(can_stop(&state).unwrap_err().contains("post-write"));
    }

    #[test]
    fn can_stop_postwrite_review_denies() {
        let state = make_state(AuthorPhase::PostwriteReview, ApprovalMode::Interactive);
        assert!(can_stop(&state).unwrap_err().contains("post-write"));
    }

    #[test]
    fn next_action_none() {
        assert_eq!(next_action(None), AuthorNextAction::ReloadState);
        assert!(next_action(None).to_string().contains("Reload"));
    }

    #[test]
    fn next_action_bypass() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Bypass);
        assert_eq!(next_action(Some(&state)), AuthorNextAction::ContinueBypass);
        assert!(next_action(Some(&state)).to_string().contains("bypass"));
    }

    #[test]
    fn next_action_each_phase() {
        let phases = [
            (AuthorPhase::Discovery, "discovery"),
            (AuthorPhase::PrewriteReview, "pre-write"),
            (AuthorPhase::PostwriteReview, "post-write"),
            (AuthorPhase::Cancelled, "cancelled"),
            (AuthorPhase::Complete, "approved"),
        ];
        for (phase, expected_substr) in phases {
            let state = make_state(phase, ApprovalMode::Interactive);
            let action = next_action(Some(&state));
            assert!(
                action.to_string().to_lowercase().contains(expected_substr),
                "phase {phase:?} action should contain '{expected_substr}': {action}"
            );
        }
    }

    #[test]
    fn next_action_writing_with_suite_written() {
        let mut state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        state.draft.suite_tree_written = true;
        assert_eq!(next_action(Some(&state)), AuthorNextAction::ApplyEditRound);
        assert!(next_action(Some(&state)).to_string().contains("edit round"));
    }

    #[test]
    fn next_action_writing_without_suite_written() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert_eq!(
            next_action(Some(&state)),
            AuthorNextAction::ContinueInitialWrite
        );
        assert!(next_action(Some(&state)).to_string().contains("initial"));
    }

    #[test]
    fn suite_author_path_allowed_suite_md() {
        let suite = Path::new("/tmp/suite");
        assert!(suite_author_path_allowed(&suite.join("suite.md"), suite));
    }

    #[test]
    fn suite_author_path_allowed_groups() {
        let suite = Path::new("/tmp/suite");
        assert!(suite_author_path_allowed(
            &suite.join("groups").join("g1.md"),
            suite
        ));
    }

    #[test]
    fn suite_author_path_allowed_baseline() {
        let suite = Path::new("/tmp/suite");
        assert!(suite_author_path_allowed(
            &suite.join("baseline").join("b1.yaml"),
            suite
        ));
    }

    #[test]
    fn suite_author_path_denied_outside() {
        let suite = Path::new("/tmp/suite");
        assert!(!suite_author_path_allowed(
            Path::new("/tmp/other/file.md"),
            suite
        ));
    }

    #[test]
    fn suite_author_path_denied_random_file_in_suite() {
        let suite = Path::new("/tmp/suite");
        assert!(!suite_author_path_allowed(&suite.join("random.txt"), suite));
    }

    #[test]
    fn has_written_suite_delegates_to_draft() {
        let mut state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert!(!state.has_written_suite());
        state.draft.suite_tree_written = true;
        assert!(state.has_written_suite());
    }

    #[test]
    fn session_info_suite_path() {
        let info = AuthorSessionInfo {
            repo_root: None,
            feature: None,
            suite_name: None,
            suite_dir: Some("/tmp/suite".to_string()),
        };
        assert_eq!(info.suite_path(), Some(PathBuf::from("/tmp/suite")));

        let info_none = AuthorSessionInfo {
            repo_root: None,
            feature: None,
            suite_name: None,
            suite_dir: None,
        };
        assert_eq!(info_none.suite_path(), None);
    }
}
