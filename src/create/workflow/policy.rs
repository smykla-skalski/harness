use std::fmt;
use std::path::Path;

use super::{ApprovalMode, CreatePhase, CreateWorkflowState, ReviewGate};

/// Check if writing is allowed in the current state.
///
/// # Errors
/// Returns a static reason string when writing is not allowed.
pub fn can_write(state: &CreateWorkflowState) -> Result<(), &'static str> {
    if state.mode() == ApprovalMode::Bypass {
        return Ok(());
    }
    match state.phase() {
        CreatePhase::Writing => Ok(()),
        CreatePhase::PrewriteReview => {
            Err("wait for the current pre-write approval answer before writing suite files")
        }
        CreatePhase::PostwriteReview => {
            Err("wait for the current post-write approval answer before editing the saved suite")
        }
        CreatePhase::Complete => {
            Err("the saved suite is already approved; request changes before editing it again")
        }
        CreatePhase::Cancelled => {
            Err("the suite:create flow was cancelled; restart create before writing again")
        }
        CreatePhase::Discovery => {
            Err("suite:create is still collecting context before the first review gate")
        }
    }
}

/// Check if a review gate can be requested.
///
/// # Errors
/// Returns a static reason string when the gate cannot be requested.
pub fn can_request_gate(state: &CreateWorkflowState, gate: ReviewGate) -> Result<(), &'static str> {
    if state.mode() == ApprovalMode::Bypass {
        return Err("bypass mode forbids canonical review prompts");
    }
    match gate {
        ReviewGate::Prewrite => {
            if state.phase() == CreatePhase::PrewriteReview {
                Ok(())
            } else {
                Err("pre-write approval can only run while the proposal is still pending")
            }
        }
        ReviewGate::Postwrite => {
            if !state.has_written_suite() {
                return Err("ask post-write approval before stopping after suite writes");
            }
            if state.phase() == CreatePhase::Writing {
                Ok(())
            } else {
                Err("post-write approval is only valid after initial writes or an edit round")
            }
        }
        ReviewGate::Copy => {
            if state.phase() == CreatePhase::Complete {
                Ok(())
            } else {
                Err("copy prompt is only valid after the saved suite is approved")
            }
        }
    }
}

/// Check if the create flow can be stopped.
///
/// # Errors
/// Returns a static reason string when stopping is not allowed.
pub fn can_stop(state: &CreateWorkflowState) -> Result<(), &'static str> {
    if state.mode() == ApprovalMode::Bypass {
        return Ok(());
    }
    match state.phase() {
        CreatePhase::Writing => Err("ask the post-write approval gate before stopping"),
        CreatePhase::PostwriteReview => {
            Err("wait for the current post-write approval answer before stopping")
        }
        _ => Ok(()),
    }
}

/// Next action for an create workflow state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CreateNextAction {
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

impl fmt::Display for CreateNextAction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::ReloadState => {
                "Reload the saved suite:create state before continuing."
            }
            Self::ContinueBypass => {
                "Continue suite:create in bypass mode using the saved create payloads."
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
                "The suite:create flow was cancelled. Do not write more files unless restarted."
            }
            Self::OfferCopyGate => {
                "The suite is approved. Offer the copy gate or stop the skill."
            }
        })
    }
}

/// Get the next action hint based on create state.
#[must_use]
pub fn next_action(state: Option<&CreateWorkflowState>) -> CreateNextAction {
    let Some(state) = state else {
        return CreateNextAction::ReloadState;
    };
    if state.mode() == ApprovalMode::Bypass {
        return CreateNextAction::ContinueBypass;
    }
    match state.phase() {
        CreatePhase::Discovery => CreateNextAction::ResumeDiscovery,
        CreatePhase::PrewriteReview => CreateNextAction::ResumePrewriteReview,
        CreatePhase::Writing => {
            if state.has_written_suite() {
                CreateNextAction::ApplyEditRound
            } else {
                CreateNextAction::ContinueInitialWrite
            }
        }
        CreatePhase::PostwriteReview => CreateNextAction::ResumePostwriteReview,
        CreatePhase::Cancelled => CreateNextAction::Stopped,
        CreatePhase::Complete => CreateNextAction::OfferCopyGate,
    }
}

/// Check if a path is allowed for suite:create writes.
#[must_use]
pub fn suite_create_path_allowed(path: &Path, suite_dir: &Path) -> bool {
    if path == suite_dir.join("suite.md") {
        return true;
    }
    if path.starts_with(suite_dir.join("groups")) {
        return true;
    }
    path.starts_with(suite_dir.join("baseline"))
}
