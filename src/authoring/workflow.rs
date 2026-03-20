use std::fmt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[path = "workflow/storage.rs"]
mod storage;

pub use self::storage::{author_state_path, read_author_state, write_author_state};

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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthorWorkflowState {
    pub mode: ApprovalMode,
    pub phase: AuthorPhase,
    pub session: AuthorSessionInfo,
    pub review: AuthorReviewState,
    pub draft: AuthorDraftState,
    pub updated_at: String,
    pub transition_count: u32,
    pub last_event: Option<String>,
}

impl AuthorWorkflowState {
    #[must_use]
    pub fn new(mode: ApprovalMode, suite_dir: Option<String>, occurred_at: String) -> Self {
        let phase = if mode == ApprovalMode::Bypass {
            AuthorPhase::Writing
        } else {
            AuthorPhase::Discovery
        };
        Self {
            mode,
            phase,
            session: AuthorSessionInfo {
                repo_root: None,
                feature: None,
                suite_name: None,
                suite_dir,
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
            updated_at: occurred_at,
            transition_count: 0,
            last_event: Some("ApprovalFlowStarted".to_string()),
        }
    }

    #[must_use]
    pub fn mode(&self) -> ApprovalMode {
        self.mode
    }

    #[must_use]
    pub fn phase(&self) -> AuthorPhase {
        self.phase
    }

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

/// Check if writing is allowed in the current state.
///
/// # Errors
/// Returns a static reason string when writing is not allowed.
pub fn can_write(state: &AuthorWorkflowState) -> Result<(), &'static str> {
    if state.mode() == ApprovalMode::Bypass {
        return Ok(());
    }
    match state.phase() {
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
            Err("the suite:new flow was cancelled; restart authoring before writing again")
        }
        AuthorPhase::Discovery => {
            Err("suite:new is still collecting context before the first review gate")
        }
    }
}

/// Check if a review gate can be requested.
///
/// # Errors
/// Returns a static reason string when the gate cannot be requested.
pub fn can_request_gate(state: &AuthorWorkflowState, gate: ReviewGate) -> Result<(), &'static str> {
    if state.mode() == ApprovalMode::Bypass {
        return Err("bypass mode forbids canonical review prompts");
    }
    match gate {
        ReviewGate::Prewrite => {
            if state.phase() == AuthorPhase::PrewriteReview {
                Ok(())
            } else {
                Err("pre-write approval can only run while the proposal is still pending")
            }
        }
        ReviewGate::Postwrite => {
            if !state.has_written_suite() {
                return Err("ask post-write approval before stopping after suite writes");
            }
            if state.phase() == AuthorPhase::Writing {
                Ok(())
            } else {
                Err("post-write approval is only valid after initial writes or an edit round")
            }
        }
        ReviewGate::Copy => {
            if state.phase() == AuthorPhase::Complete {
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
    if state.mode() == ApprovalMode::Bypass {
        return Ok(());
    }
    match state.phase() {
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
                "Reload the saved suite:new state before continuing."
            }
            Self::ContinueBypass => {
                "Continue suite:new in bypass mode using the saved authoring payloads."
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
                "The suite:new flow was cancelled. Do not write more files unless restarted."
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
    if state.mode() == ApprovalMode::Bypass {
        return AuthorNextAction::ContinueBypass;
    }
    match state.phase() {
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

/// Check if a path is allowed for suite:new writes.
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
#[path = "workflow/tests.rs"]
mod tests;
