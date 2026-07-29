use std::fmt;

use async_trait::async_trait;
use harness_kernel::errors::{CliError, CliErrorKind};
use serde::{Deserialize, Serialize};

pub use harness_protocol::managed_agents::runtime_failures::{
    AgentTurnFailure, AgentTurnFailureCategory, AgentTurnFailureStage,
};
pub use pull_request::{
    AgentTurnPullRequest, AgentTurnPullRequestContext, AgentTurnReadOnlyContent,
};

#[cfg(any(test, feature = "test-support"))]
pub mod fake;
mod pull_request;

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pull_request: Option<AgentTurnPullRequestContext>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidatedAgentTurnRequest {
    pub prompt: String,
    pub requested_model: Option<String>,
    pub pull_request: Option<AgentTurnPullRequest>,
}

impl AgentTurnRequest {
    /// Validate and freeze optional source context before a runtime starts work.
    ///
    /// # Errors
    /// Returns `CliError` when pull request identity or content is invalid.
    pub fn into_validated(self) -> Result<ValidatedAgentTurnRequest, CliError> {
        let Some(pull_request) = self.pull_request else {
            return Ok(ValidatedAgentTurnRequest {
                prompt: self.prompt,
                requested_model: self.requested_model,
                pull_request: None,
            });
        };
        pull_request.validate()?;
        let prompt = pull_request.render_prompt(&self.prompt)?;
        Ok(ValidatedAgentTurnRequest {
            prompt,
            requested_model: self.requested_model,
            pull_request: Some(pull_request.pull_request),
        })
    }
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requested_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effective_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_revision: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum AgentTurnSourceFreshness {
    Current,
    Stale {
        reviewed_revision: String,
        current_revision: String,
    },
}

impl AgentTurnResult {
    /// Compare the immutable revision reviewed by this turn with the current source revision.
    ///
    /// # Errors
    /// Returns `CliError` when either revision is unavailable.
    pub fn source_freshness(
        &self,
        current_revision: &str,
    ) -> Result<AgentTurnSourceFreshness, CliError> {
        let reviewed_revision = self
            .source_revision
            .as_deref()
            .map(str::trim)
            .filter(|revision| !revision.is_empty())
            .ok_or_else(|| {
                CliErrorKind::invalid_transition(
                    "agent turn result has no immutable source revision",
                )
            })?;
        let current_revision = current_revision.trim();
        if current_revision.is_empty() {
            return Err(
                CliErrorKind::invalid_transition("current source revision is empty").into(),
            );
        }
        if reviewed_revision == current_revision {
            Ok(AgentTurnSourceFreshness::Current)
        } else {
            Ok(AgentTurnSourceFreshness::Stale {
                reviewed_revision: reviewed_revision.to_string(),
                current_revision: current_revision.to_string(),
            })
        }
    }
}

#[async_trait]
pub trait AgentTurnRuntime: Send + Sync {
    fn runtime(&self) -> &str;

    #[must_use]
    fn classify_error(&self, stage: AgentTurnFailureStage, error: &CliError) -> AgentTurnFailure {
        AgentTurnFailure::new(
            AgentTurnFailureCategory::from_message(&error.to_string()),
            stage,
            format!(
                "{} {} failed with {}",
                self.runtime(),
                stage.as_str(),
                error.code()
            ),
        )
    }

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

    /// Read the structured terminal failure, if the turn failed or was cancelled.
    ///
    /// # Errors
    /// Returns `CliError` when the turn is unknown or its failure cannot be read.
    async fn failure(&self, id: &AgentTurnId) -> Result<Option<AgentTurnFailure>, CliError>;

    /// Cancel a turn.
    ///
    /// Cancellation is idempotent. A completed, failed, or cancelled turn keeps
    /// its existing terminal state, and a completed turn keeps its result.
    ///
    /// # Errors
    /// Returns `CliError` when the turn is unknown or cancellation cannot be applied.
    async fn cancel(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError>;
}
