use serde::{Deserialize, Serialize};

use crate::task_board::AgentMode;

/// Runtime capability required by the frozen Task Board launch decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardLaunchCapability {
    ReportReadOnly,
    WorkspaceWrite,
}

impl TaskBoardLaunchCapability {
    #[must_use]
    pub const fn is_read_only(self) -> bool {
        matches!(self, Self::ReportReadOnly)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum TaskBoardLaunchCapabilityError {
    #[error("interactive Task Board launches cannot enforce an admission capability")]
    InteractiveNotEnforceable,
    #[error("agent mode '{mode:?}' requires '{expected:?}', not '{actual:?}'")]
    CapabilityMismatch {
        mode: AgentMode,
        expected: TaskBoardLaunchCapability,
        actual: TaskBoardLaunchCapability,
    },
}

/// Resolve the capability the runtime request must enforce.
///
/// # Errors
/// Returns an error because interactive launches cannot enforce this contract.
pub const fn launch_capability_for_agent_mode(
    mode: AgentMode,
) -> Result<TaskBoardLaunchCapability, TaskBoardLaunchCapabilityError> {
    match mode {
        AgentMode::Planning | AgentMode::Evaluate => Ok(TaskBoardLaunchCapability::ReportReadOnly),
        AgentMode::Headless => Ok(TaskBoardLaunchCapability::WorkspaceWrite),
        AgentMode::Interactive => Err(TaskBoardLaunchCapabilityError::InteractiveNotEnforceable),
    }
}

/// Fail closed if the constructed runtime request does not match the frozen
/// capability decision.
///
/// # Errors
/// Returns an error for interactive mode or a capability mismatch.
pub fn validate_launch_capability(
    mode: AgentMode,
    actual: TaskBoardLaunchCapability,
) -> Result<(), TaskBoardLaunchCapabilityError> {
    let expected = launch_capability_for_agent_mode(mode)?;
    if actual == expected {
        Ok(())
    } else {
        Err(TaskBoardLaunchCapabilityError::CapabilityMismatch {
            mode,
            expected,
            actual,
        })
    }
}
