use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[path = "workflow/policy.rs"]
mod policy;
#[path = "workflow/storage.rs"]
mod storage;

pub use self::policy::{
    CreateNextAction, can_request_gate, can_stop, can_write, next_action, suite_create_path_allowed,
};
pub use self::storage::{create_state_path, read_create_state, write_create_state};

/// Create approval mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum ApprovalMode {
    Interactive,
    Bypass,
}

/// Create workflow phases.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum CreatePhase {
    Discovery,
    PrewriteReview,
    Writing,
    PostwriteReview,
    Complete,
    Cancelled,
}

impl fmt::Display for CreatePhase {
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
pub enum CreateAnswer {
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

/// Session info within create state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateSessionInfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo_root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub feature: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_dir: Option<String>,
}

impl CreateSessionInfo {
    #[must_use]
    pub fn suite_path(&self) -> Option<PathBuf> {
        self.suite_dir.as_ref().map(PathBuf::from)
    }
}

/// Review sub-state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateReviewState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gate: Option<ReviewGate>,
    #[serde(default)]
    pub awaiting_answer: bool,
    #[serde(default)]
    pub round: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_answer: Option<CreateAnswer>,
}

/// Draft sub-state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateDraftState {
    #[serde(default)]
    pub suite_tree_written: bool,
    #[serde(default)]
    pub written_paths: Vec<String>,
}

/// Full create workflow state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateWorkflowState {
    pub mode: ApprovalMode,
    pub phase: CreatePhase,
    pub session: CreateSessionInfo,
    pub review: CreateReviewState,
    pub draft: CreateDraftState,
    pub updated_at: String,
    pub transition_count: u32,
    pub last_event: Option<String>,
}

impl CreateWorkflowState {
    #[must_use]
    pub fn new(mode: ApprovalMode, suite_dir: Option<String>, occurred_at: String) -> Self {
        let phase = if mode == ApprovalMode::Bypass {
            CreatePhase::Writing
        } else {
            CreatePhase::Discovery
        };
        Self {
            mode,
            phase,
            session: CreateSessionInfo {
                repo_root: None,
                feature: None,
                suite_name: None,
                suite_dir,
            },
            review: CreateReviewState {
                gate: None,
                awaiting_answer: false,
                round: 0,
                last_answer: None,
            },
            draft: CreateDraftState {
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
    pub fn phase(&self) -> CreatePhase {
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

#[cfg(test)]
#[path = "workflow/tests.rs"]
mod tests;
