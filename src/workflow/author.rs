use std::env;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::workflow::engine::{TransitionError, VersionedJsonRepository};

/// Author approval mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum ApprovalMode {
    Interactive,
    Bypass,
}

/// Author workflow phases with associated state data.
///
/// Review data only exists in review phases. Draft data only exists
/// once writing has started. Invalid combinations are unrepresentable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "name", rename_all = "snake_case")]
#[non_exhaustive]
pub enum AuthorPhase {
    Discovery,
    PrewriteReview {
        review: AuthorReviewState,
    },
    Writing {
        draft: AuthorDraftState,
    },
    PostwriteReview {
        review: AuthorReviewState,
        draft: AuthorDraftState,
    },
    Complete {
        draft: AuthorDraftState,
    },
    Cancelled,
}

impl AuthorPhase {
    /// Short lowercase name for display and CLI output.
    #[must_use]
    pub fn name(&self) -> &'static str {
        match self {
            Self::Discovery => "discovery",
            Self::PrewriteReview { .. } => "prewrite_review",
            Self::Writing { .. } => "writing",
            Self::PostwriteReview { .. } => "postwrite_review",
            Self::Complete { .. } => "complete",
            Self::Cancelled => "cancelled",
        }
    }
}

/// Typed events for author state transitions.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum AuthorEvent {
    ApprovalFlowStarted,
    ProposalReady,
    PrewriteApproved,
    PrewriteChangesRequested,
    WritingStarted,
    SuiteWritten,
    PostwriteApproved,
    PostwriteChangesRequested,
    FlowCompleted,
    FlowCancelled,
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
    pub updated_at: String,
    pub transition_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event: Option<AuthorEvent>,
}

const AUTHOR_STATE_SCHEMA_VERSION: u32 = 2;

impl AuthorWorkflowState {
    /// Apply a state transition, returning the new state.
    ///
    /// # Errors
    /// Returns `TransitionError` if the transition is not allowed.
    pub fn transition(
        &self,
        event: AuthorEvent,
        new_phase: AuthorPhase,
    ) -> Result<Self, TransitionError> {
        if !self.can_transition(&new_phase) {
            return Err(TransitionError(format!(
                "invalid transition from {} to {}",
                self.phase.name(),
                new_phase.name(),
            )));
        }
        Ok(Self {
            schema_version: self.schema_version,
            mode: self.mode,
            phase: new_phase,
            session: self.session.clone(),
            updated_at: now_utc(),
            transition_count: self.transition_count + 1,
            last_event: Some(event),
        })
    }

    /// Check whether a transition to `target` is allowed.
    #[must_use]
    pub fn can_transition(&self, target: &AuthorPhase) -> bool {
        matches!(
            (&self.phase, target),
            (
                AuthorPhase::Discovery,
                AuthorPhase::PrewriteReview { .. } | AuthorPhase::Writing { .. },
            ) | (
                AuthorPhase::PrewriteReview { .. },
                AuthorPhase::PrewriteReview { .. } | AuthorPhase::Writing { .. },
            ) | (
                AuthorPhase::Writing { .. },
                AuthorPhase::PostwriteReview { .. } | AuthorPhase::Complete { .. },
            ) | (
                AuthorPhase::PostwriteReview { .. },
                AuthorPhase::PostwriteReview { .. }
                    | AuthorPhase::Writing { .. }
                    | AuthorPhase::Complete { .. },
            ) | (_, AuthorPhase::Cancelled)
        )
    }

    #[must_use]
    pub fn has_written_suite(&self) -> bool {
        match &self.phase {
            AuthorPhase::Writing { draft }
            | AuthorPhase::PostwriteReview { draft, .. }
            | AuthorPhase::Complete { draft } => draft.suite_tree_written,
            _ => false,
        }
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

fn now_utc() -> String {
    chrono::Utc::now().to_rfc3339()
}

/// Path to the author state file.
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn author_state_path() -> Result<PathBuf, CliError> {
    let cwd = env::current_dir().map_err(|e| CliError {
        code: "WORKFLOW_IO".into(),
        message: format!("failed to determine current directory: {e}"),
        exit_code: 5,
        hint: None,
        details: None,
    })?;
    Ok(cwd.join(".harness").join("suite-author-state.json"))
}

fn author_repository() -> Result<VersionedJsonRepository, CliError> {
    let path = author_state_path()?;
    Ok(VersionedJsonRepository::new(
        path,
        AUTHOR_STATE_SCHEMA_VERSION,
    ))
}

/// Read author state from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn read_author_state() -> Result<Option<AuthorWorkflowState>, CliError> {
    let repo = author_repository()?;
    match repo.load()? {
        Some(value) => {
            let state: AuthorWorkflowState =
                serde_json::from_value(value).map_err(|e| CliError {
                    code: "WORKFLOW_PARSE".into(),
                    message: format!("failed to parse author state: {e}"),
                    exit_code: 5,
                    hint: None,
                    details: None,
                })?;
            Ok(Some(state))
        }
        None => Ok(None),
    }
}

/// Write author state to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_author_state(state: &AuthorWorkflowState) -> Result<(), CliError> {
    let repo = author_repository()?;
    let value = serde_json::to_value(state).map_err(|e| CliError {
        code: "WORKFLOW_SERIALIZE".into(),
        message: format!("failed to serialize author state: {e}"),
        exit_code: 5,
        hint: None,
        details: None,
    })?;
    repo.save(&value)?;
    Ok(())
}

/// Check if writing is allowed in the current state.
#[must_use]
pub fn can_write(state: &AuthorWorkflowState) -> (bool, Option<&'static str>) {
    if state.mode == ApprovalMode::Bypass {
        return (true, None);
    }
    match &state.phase {
        AuthorPhase::Writing { .. } => (true, None),
        AuthorPhase::PrewriteReview { .. } => (
            false,
            Some("wait for the current pre-write approval answer before writing suite files"),
        ),
        AuthorPhase::PostwriteReview { .. } => (
            false,
            Some("wait for the current post-write approval answer before editing the saved suite"),
        ),
        AuthorPhase::Complete { .. } => (
            false,
            Some("the saved suite is already approved; request changes before editing it again"),
        ),
        AuthorPhase::Cancelled => (
            false,
            Some("the suite-author flow was cancelled; restart authoring before writing again"),
        ),
        AuthorPhase::Discovery => (
            false,
            Some("suite-author is still collecting context before the first review gate"),
        ),
    }
}

/// Check if a review gate can be requested.
#[must_use]
pub fn can_request_gate(
    state: &AuthorWorkflowState,
    gate: ReviewGate,
) -> (bool, Option<&'static str>) {
    if state.mode == ApprovalMode::Bypass {
        return (false, Some("bypass mode forbids canonical review prompts"));
    }
    match gate {
        ReviewGate::Prewrite => {
            if matches!(&state.phase, AuthorPhase::PrewriteReview { .. }) {
                (true, None)
            } else {
                (
                    false,
                    Some("pre-write approval can only run while the proposal is still pending"),
                )
            }
        }
        ReviewGate::Postwrite => {
            if !state.has_written_suite() {
                return (
                    false,
                    Some("ask post-write approval before stopping after suite writes"),
                );
            }
            if matches!(&state.phase, AuthorPhase::Writing { .. }) {
                (true, None)
            } else {
                (
                    false,
                    Some("post-write approval is only valid after initial writes or an edit round"),
                )
            }
        }
        ReviewGate::Copy => {
            if matches!(&state.phase, AuthorPhase::Complete { .. }) {
                (true, None)
            } else {
                (
                    false,
                    Some("copy prompt is only valid after the saved suite is approved"),
                )
            }
        }
    }
}

/// Check if the author flow can be stopped.
#[must_use]
pub fn can_stop(state: &AuthorWorkflowState) -> (bool, Option<&'static str>) {
    if state.mode == ApprovalMode::Bypass {
        return (true, None);
    }
    match &state.phase {
        AuthorPhase::Writing { .. } => (
            false,
            Some("ask the post-write approval gate before stopping"),
        ),
        AuthorPhase::PostwriteReview { .. } => (
            false,
            Some("wait for the current post-write approval answer before stopping"),
        ),
        _ => (true, None),
    }
}

/// Get the next action hint based on author state.
#[must_use]
pub fn next_action(state: Option<&AuthorWorkflowState>) -> String {
    let Some(state) = state else {
        return "Reload the saved suite-author state before continuing.".to_string();
    };
    if state.mode == ApprovalMode::Bypass {
        return "Continue suite-author in bypass mode using the saved authoring payloads."
            .to_string();
    }
    match &state.phase {
        AuthorPhase::Discovery => {
            "Resume discovery and proposal preparation before reopening review."
                .to_string()
        }
        AuthorPhase::PrewriteReview { .. } => {
            "Resume the pre-write review loop and ask the pre-write gate question before writing suite files."
                .to_string()
        }
        AuthorPhase::Writing { draft } => {
            if draft.suite_tree_written {
                "Apply the current edit round, then reopen the post-write review gate."
                    .to_string()
            } else {
                "Continue the initial suite write phase from the saved proposal."
                    .to_string()
            }
        }
        AuthorPhase::PostwriteReview { .. } => {
            "Resume the post-write review loop and ask the post-write gate question before stopping."
                .to_string()
        }
        AuthorPhase::Cancelled => {
            "The suite-author flow was cancelled. Do not write more files unless restarted."
                .to_string()
        }
        AuthorPhase::Complete { .. } => {
            "The suite is approved. Offer the copy gate or stop the skill."
                .to_string()
        }
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
            schema_version: 2,
            mode,
            phase,
            session: AuthorSessionInfo {
                repo_root: None,
                feature: None,
                suite_name: None,
                suite_dir: Some("/tmp/suite".to_string()),
            },
            updated_at: "2025-01-01T00:00:00Z".to_string(),
            transition_count: 0,
            last_event: None,
        }
    }

    fn default_review() -> AuthorReviewState {
        AuthorReviewState {
            gate: None,
            awaiting_answer: false,
            round: 0,
            last_answer: None,
        }
    }

    fn default_draft() -> AuthorDraftState {
        AuthorDraftState {
            suite_tree_written: false,
            written_paths: vec![],
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
        let cases: Vec<(AuthorPhase, &str)> = vec![
            (AuthorPhase::Discovery, "discovery"),
            (
                AuthorPhase::PrewriteReview {
                    review: default_review(),
                },
                "prewrite_review",
            ),
            (
                AuthorPhase::Writing {
                    draft: default_draft(),
                },
                "writing",
            ),
            (
                AuthorPhase::PostwriteReview {
                    review: default_review(),
                    draft: default_draft(),
                },
                "postwrite_review",
            ),
            (
                AuthorPhase::Complete {
                    draft: default_draft(),
                },
                "complete",
            ),
            (AuthorPhase::Cancelled, "cancelled"),
        ];
        for (variant, expected) in cases {
            let json = serde_json::to_value(&variant).unwrap();
            assert_eq!(json["name"], expected);
        }
    }

    #[test]
    fn author_phase_round_trip() {
        let phase = AuthorPhase::Writing {
            draft: AuthorDraftState {
                suite_tree_written: true,
                written_paths: vec!["a.md".to_string()],
            },
        };
        let json = serde_json::to_value(&phase).unwrap();
        let loaded: AuthorPhase = serde_json::from_value(json).unwrap();
        assert_eq!(loaded, phase);
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
    fn author_event_serialization() {
        let json = serde_json::to_value(AuthorEvent::ApprovalFlowStarted).unwrap();
        assert_eq!(json, "approval_flow_started");
        let loaded: AuthorEvent = serde_json::from_value(json).unwrap();
        assert_eq!(loaded, AuthorEvent::ApprovalFlowStarted);
    }

    #[test]
    fn full_state_serialization_round_trip() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: default_draft(),
            },
            ApprovalMode::Interactive,
        );
        let json = serde_json::to_value(&state).unwrap();
        let loaded: AuthorWorkflowState = serde_json::from_value(json).unwrap();
        assert_eq!(loaded, state);
    }

    #[test]
    fn can_write_bypass_always_allows() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Bypass);
        let (allowed, reason) = can_write(&state);
        assert!(allowed);
        assert!(reason.is_none());
    }

    #[test]
    fn can_write_writing_phase_allows() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: default_draft(),
            },
            ApprovalMode::Interactive,
        );
        let (allowed, _) = can_write(&state);
        assert!(allowed);
    }

    #[test]
    fn can_write_discovery_denies() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Interactive);
        let (allowed, reason) = can_write(&state);
        assert!(!allowed);
        assert!(reason.is_some());
    }

    #[test]
    fn can_write_prewrite_review_denies() {
        let state = make_state(
            AuthorPhase::PrewriteReview {
                review: default_review(),
            },
            ApprovalMode::Interactive,
        );
        let (allowed, reason) = can_write(&state);
        assert!(!allowed);
        assert!(reason.unwrap().contains("pre-write"));
    }

    #[test]
    fn can_write_postwrite_review_denies() {
        let state = make_state(
            AuthorPhase::PostwriteReview {
                review: default_review(),
                draft: default_draft(),
            },
            ApprovalMode::Interactive,
        );
        let (allowed, reason) = can_write(&state);
        assert!(!allowed);
        assert!(reason.unwrap().contains("post-write"));
    }

    #[test]
    fn can_write_complete_denies() {
        let state = make_state(
            AuthorPhase::Complete {
                draft: default_draft(),
            },
            ApprovalMode::Interactive,
        );
        let (allowed, reason) = can_write(&state);
        assert!(!allowed);
        assert!(reason.unwrap().contains("approved"));
    }

    #[test]
    fn can_write_cancelled_denies() {
        let state = make_state(AuthorPhase::Cancelled, ApprovalMode::Interactive);
        let (allowed, reason) = can_write(&state);
        assert!(!allowed);
        assert!(reason.unwrap().contains("cancelled"));
    }

    #[test]
    fn can_request_gate_bypass_denies() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: default_draft(),
            },
            ApprovalMode::Bypass,
        );
        let (allowed, reason) = can_request_gate(&state, ReviewGate::Postwrite);
        assert!(!allowed);
        assert!(reason.unwrap().contains("bypass"));
    }

    #[test]
    fn can_request_prewrite_gate_in_prewrite_review() {
        let state = make_state(
            AuthorPhase::PrewriteReview {
                review: default_review(),
            },
            ApprovalMode::Interactive,
        );
        let (allowed, _) = can_request_gate(&state, ReviewGate::Prewrite);
        assert!(allowed);
    }

    #[test]
    fn can_request_prewrite_gate_wrong_phase() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: default_draft(),
            },
            ApprovalMode::Interactive,
        );
        let (allowed, _) = can_request_gate(&state, ReviewGate::Prewrite);
        assert!(!allowed);
    }

    #[test]
    fn can_request_postwrite_gate_after_writing() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: AuthorDraftState {
                    suite_tree_written: true,
                    written_paths: vec![],
                },
            },
            ApprovalMode::Interactive,
        );
        let (allowed, _) = can_request_gate(&state, ReviewGate::Postwrite);
        assert!(allowed);
    }

    #[test]
    fn can_request_postwrite_gate_without_writes_denies() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: default_draft(),
            },
            ApprovalMode::Interactive,
        );
        let (allowed, _) = can_request_gate(&state, ReviewGate::Postwrite);
        assert!(!allowed);
    }

    #[test]
    fn can_request_copy_gate_in_complete() {
        let state = make_state(
            AuthorPhase::Complete {
                draft: default_draft(),
            },
            ApprovalMode::Interactive,
        );
        let (allowed, _) = can_request_gate(&state, ReviewGate::Copy);
        assert!(allowed);
    }

    #[test]
    fn can_request_copy_gate_wrong_phase() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: default_draft(),
            },
            ApprovalMode::Interactive,
        );
        let (allowed, _) = can_request_gate(&state, ReviewGate::Copy);
        assert!(!allowed);
    }

    #[test]
    fn can_stop_bypass_allows() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: default_draft(),
            },
            ApprovalMode::Bypass,
        );
        let (allowed, _) = can_stop(&state);
        assert!(allowed);
    }

    #[test]
    fn can_stop_cancelled_allows() {
        let state = make_state(AuthorPhase::Cancelled, ApprovalMode::Interactive);
        let (allowed, _) = can_stop(&state);
        assert!(allowed);
    }

    #[test]
    fn can_stop_writing_denies() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: default_draft(),
            },
            ApprovalMode::Interactive,
        );
        let (allowed, reason) = can_stop(&state);
        assert!(!allowed);
        assert!(reason.unwrap().contains("post-write"));
    }

    #[test]
    fn can_stop_postwrite_review_denies() {
        let state = make_state(
            AuthorPhase::PostwriteReview {
                review: default_review(),
                draft: default_draft(),
            },
            ApprovalMode::Interactive,
        );
        let (allowed, reason) = can_stop(&state);
        assert!(!allowed);
        assert!(reason.unwrap().contains("post-write"));
    }

    #[test]
    fn next_action_none() {
        let action = next_action(None);
        assert!(action.contains("Reload"));
    }

    #[test]
    fn next_action_bypass() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Bypass);
        let action = next_action(Some(&state));
        assert!(action.contains("bypass"));
    }

    #[test]
    fn next_action_each_phase() {
        let phases: Vec<(AuthorPhase, &str)> = vec![
            (AuthorPhase::Discovery, "discovery"),
            (
                AuthorPhase::PrewriteReview {
                    review: default_review(),
                },
                "pre-write",
            ),
            (
                AuthorPhase::PostwriteReview {
                    review: default_review(),
                    draft: default_draft(),
                },
                "post-write",
            ),
            (AuthorPhase::Cancelled, "cancelled"),
            (
                AuthorPhase::Complete {
                    draft: default_draft(),
                },
                "approved",
            ),
        ];
        for (phase, expected_substr) in phases {
            let state = make_state(phase.clone(), ApprovalMode::Interactive);
            let action = next_action(Some(&state));
            assert!(
                action.to_lowercase().contains(expected_substr),
                "phase {} action should contain '{expected_substr}': {action}",
                phase.name()
            );
        }
    }

    #[test]
    fn next_action_writing_with_suite_written() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: AuthorDraftState {
                    suite_tree_written: true,
                    written_paths: vec![],
                },
            },
            ApprovalMode::Interactive,
        );
        let action = next_action(Some(&state));
        assert!(action.contains("edit round"));
    }

    #[test]
    fn next_action_writing_without_suite_written() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: default_draft(),
            },
            ApprovalMode::Interactive,
        );
        let action = next_action(Some(&state));
        assert!(action.contains("initial"));
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
    fn has_written_suite_from_writing_phase() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: AuthorDraftState {
                    suite_tree_written: true,
                    written_paths: vec![],
                },
            },
            ApprovalMode::Interactive,
        );
        assert!(state.has_written_suite());
    }

    #[test]
    fn has_written_suite_false_in_discovery() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Interactive);
        assert!(!state.has_written_suite());
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

    // Transition tests
    #[test]
    fn transition_discovery_to_prewrite() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Interactive);
        let result = state.transition(
            AuthorEvent::ProposalReady,
            AuthorPhase::PrewriteReview {
                review: default_review(),
            },
        );
        assert!(result.is_ok());
        let new = result.unwrap();
        assert_eq!(new.transition_count, 1);
        assert_eq!(new.last_event, Some(AuthorEvent::ProposalReady));
    }

    #[test]
    fn transition_discovery_to_writing_bypass() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Bypass);
        let result = state.transition(
            AuthorEvent::WritingStarted,
            AuthorPhase::Writing {
                draft: default_draft(),
            },
        );
        assert!(result.is_ok());
    }

    #[test]
    fn transition_rejects_discovery_to_complete() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Interactive);
        let result = state.transition(
            AuthorEvent::FlowCompleted,
            AuthorPhase::Complete {
                draft: default_draft(),
            },
        );
        assert!(result.is_err());
    }

    #[test]
    fn transition_any_to_cancelled() {
        let state = make_state(
            AuthorPhase::Writing {
                draft: default_draft(),
            },
            ApprovalMode::Interactive,
        );
        let result = state.transition(AuthorEvent::FlowCancelled, AuthorPhase::Cancelled);
        assert!(result.is_ok());
    }

    #[test]
    fn phase_name_returns_correct_string() {
        assert_eq!(AuthorPhase::Discovery.name(), "discovery");
        assert_eq!(
            AuthorPhase::PrewriteReview {
                review: default_review()
            }
            .name(),
            "prewrite_review"
        );
        assert_eq!(
            AuthorPhase::Writing {
                draft: default_draft()
            }
            .name(),
            "writing"
        );
    }
}
