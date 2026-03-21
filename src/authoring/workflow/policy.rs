use std::fmt;
use std::path::Path;

use super::{ApprovalMode, AuthorPhase, AuthorWorkflowState, ReviewGate};

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
