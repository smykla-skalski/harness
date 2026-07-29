use std::fmt;

use async_trait::async_trait;
use harness_kernel::errors::{CliError, CliErrorKind};
use serde::{Deserialize, Serialize};

#[cfg(any(test, feature = "test-support"))]
pub mod fake;

#[cfg(test)]
mod tests;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct AgentTurnId(String);

impl AgentTurnId {
    /// Create a correlation identifier returned by a runtime.
    ///
    /// # Errors
    /// Returns `CliError` when the identifier is empty.
    pub fn new(value: impl Into<String>) -> Result<Self, CliError> {
        let value = value.into();
        if value.trim().is_empty() {
            return Err(CliErrorKind::invalid_transition(
                "agent turn correlation identifier cannot be empty",
            )
            .into());
        }
        Ok(Self(value))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for AgentTurnId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTurnRequest {
    pub prompt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requested_model: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentTurnStatus {
    Queued,
    Running,
    Completed,
    Failed,
    Cancelled,
}

impl AgentTurnStatus {
    #[must_use]
    pub const fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTurnResult {
    pub correlation_id: AgentTurnId,
    pub report: String,
    pub stop_reason: String,
}

#[async_trait]
pub trait AgentTurnRuntime: Send + Sync {
    fn runtime(&self) -> &str;

    /// Start one turn and return its stable correlation identifier.
    ///
    /// # Errors
    /// Returns `CliError` when the runtime cannot accept the turn.
    async fn start(&self, request: AgentTurnRequest) -> Result<AgentTurnId, CliError>;

    /// Read the current lifecycle state.
    ///
    /// # Errors
    /// Returns `CliError` when the turn is unknown or its state cannot be read.
    async fn status(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError>;

    /// Read the single completed result, if the turn completed successfully.
    ///
    /// # Errors
    /// Returns `CliError` when the turn is unknown or its result cannot be read.
    async fn result(&self, id: &AgentTurnId) -> Result<Option<AgentTurnResult>, CliError>;

    /// Cancel a turn.
    ///
    /// Cancellation is idempotent. A completed, failed, or cancelled turn keeps
    /// its existing terminal state, and a completed turn keeps its result.
    ///
    /// # Errors
    /// Returns `CliError` when the turn is unknown or cancellation cannot be applied.
    async fn cancel(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError>;
}
