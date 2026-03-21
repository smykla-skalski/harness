use std::env;
use std::path::PathBuf;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::create::workflow::{
    ApprovalMode, CreateDraftState, CreateReviewState, CreateSessionInfo, CreateWorkflowState,
};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_text, write_json_pretty};
use crate::kernel::skills::dirs as skill_dirs;

use super::CreatePhase;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredCreateWorkflowData {
    pub phase: CreatePhase,
    pub review: CreateReviewState,
    pub draft: CreateDraftState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredCreateWorkflowState {
    pub mode: ApprovalMode,
    pub session: CreateSessionInfo,
    pub state: StoredCreateWorkflowData,
    pub updated_at: String,
    pub transition_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event: Option<String>,
}

impl CreateWorkflowState {
    fn to_stored(&self) -> StoredCreateWorkflowState {
        StoredCreateWorkflowState {
            mode: self.mode,
            session: self.session.clone(),
            state: StoredCreateWorkflowData {
                phase: self.phase,
                review: self.review.clone(),
                draft: self.draft.clone(),
            },
            updated_at: self.updated_at.clone(),
            transition_count: self.transition_count,
            last_event: self.last_event.clone(),
        }
    }

    fn from_stored(stored: StoredCreateWorkflowState) -> Self {
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

impl Serialize for CreateWorkflowState {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.to_stored().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for CreateWorkflowState {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        StoredCreateWorkflowState::deserialize(deserializer).map(Self::from_stored)
    }
}

/// Path to the create state file.
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn create_state_path() -> Result<PathBuf, CliError> {
    let cwd = env::current_dir().map_err(|error| -> CliError {
        CliErrorKind::workflow_io(format!("failed to determine current directory: {error}")).into()
    })?;
    Ok(cwd.join(".harness").join(skill_dirs::CREATE_STATE_FILE))
}

/// Read create state from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn read_create_state() -> Result<Option<CreateWorkflowState>, CliError> {
    let path = create_state_path()?;
    if !path.exists() {
        return Ok(None);
    }

    let text = read_text(&path)?;
    let state = serde_json::from_str(&text).map_err(|error| {
        CliErrorKind::workflow_parse(format!("failed to parse create workflow: {}", path.display()))
            .with_details(format!(
                "{error}\nDelete {} or re-run `harness create approval-begin` to regenerate the create state.",
                path.display()
            ))
    })?;
    Ok(Some(state))
}

/// Write create state to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_create_state(state: &CreateWorkflowState) -> Result<(), CliError> {
    write_json_pretty(&create_state_path()?, state)
}
