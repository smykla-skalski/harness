use std::env;
use std::path::PathBuf;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::authoring::workflow::{
    ApprovalMode, AuthorDraftState, AuthorReviewState, AuthorSessionInfo, AuthorWorkflowState,
};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_text, write_json_pretty};
use crate::kernel::skills::dirs as skill_dirs;

use super::AuthorPhase;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredAuthorWorkflowData {
    pub phase: AuthorPhase,
    pub review: AuthorReviewState,
    pub draft: AuthorDraftState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredAuthorWorkflowState {
    pub mode: ApprovalMode,
    pub session: AuthorSessionInfo,
    pub state: StoredAuthorWorkflowData,
    pub updated_at: String,
    pub transition_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event: Option<String>,
}

impl AuthorWorkflowState {
    fn to_stored(&self) -> StoredAuthorWorkflowState {
        StoredAuthorWorkflowState {
            mode: self.mode,
            session: self.session.clone(),
            state: StoredAuthorWorkflowData {
                phase: self.phase,
                review: self.review.clone(),
                draft: self.draft.clone(),
            },
            updated_at: self.updated_at.clone(),
            transition_count: self.transition_count,
            last_event: self.last_event.clone(),
        }
    }

    fn from_stored(stored: StoredAuthorWorkflowState) -> Self {
        Self {
            mode: stored.mode,
            phase: stored.state.phase,
            session: stored.session,
            review: stored.state.review,
            draft: stored.state.draft,
            updated_at: stored.updated_at,
            transition_count: stored.transition_count,
            last_event: stored.last_event,
        }
    }
}

impl Serialize for AuthorWorkflowState {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.to_stored().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for AuthorWorkflowState {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        StoredAuthorWorkflowState::deserialize(deserializer).map(Self::from_stored)
    }
}

/// Path to the author state file.
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn author_state_path() -> Result<PathBuf, CliError> {
    let cwd = env::current_dir().map_err(|error| -> CliError {
        CliErrorKind::workflow_io(format!("failed to determine current directory: {error}")).into()
    })?;
    Ok(cwd.join(".harness").join(skill_dirs::NEW_STATE_FILE))
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

    let text = read_text(&path)?;
    let state = serde_json::from_str(&text).map_err(|error| {
        CliErrorKind::workflow_parse(format!("failed to parse author workflow: {}", path.display()))
            .with_details(format!(
                "{error}\nDelete {} or re-run `harness authoring approval-begin` to regenerate the author state.",
                path.display()
            ))
    })?;
    Ok(Some(state))
}

/// Write author state to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_author_state(state: &AuthorWorkflowState) -> Result<(), CliError> {
    write_json_pretty(&author_state_path()?, state)
}
