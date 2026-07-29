//! `OpenRouter` implementor of the shared [`AgentTurnRuntime`] contract.
//!
//! Mirrors [`crate::daemon::codex_controller::CodexAgentTurnRuntime`] so a
//! reviewer runtime that speaks ACP presents the same start/status/result/
//! failure/cancel surface Codex already does. The turn runs over the ACP path
//! from #873: [`AcpAgentManagerHandle`] spawns the `harness-openrouter-agent`
//! shim, dispatches the initial prompt, and surfaces the terminal turn outcome
//! as `last_turn_result` / `last_turn_failure` on the live session state.
//!
//! Slice 1 of #1001 adds this adapter only; no production dispatch reaches it
//! yet. Terminal turn outcomes are read from live in-memory ACP session state
//! through `inspect`, so they are observable only while the shim stays
//! connected. Durable non-codex run storage is slice 2, and the coordinator
//! wiring plus remote runtime selection is slice 3.

use async_trait::async_trait;

use crate::agents::kind::DisconnectReason;
use crate::agents::turn::{
    AgentTurnFailure, AgentTurnFailureCategory, AgentTurnFailureStage, AgentTurnId,
    AgentTurnRequest, AgentTurnResult, AgentTurnRuntime, AgentTurnStatus,
    ValidatedAgentTurnRequest,
};
use crate::session::types::AgentStatus;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::manager::AcpAgentManagerHandle;
use super::{AcpAgentSessionState, AcpAgentSnapshot, AcpAgentStartRequest};

const OPENROUTER_RUNTIME: &str = "openrouter";
const MODEL_CONFIG_OPTION_ID: &str = "model";

/// Runs one report-style `OpenRouter` turn over ACP, bound to a Harness session.
#[derive(Clone)]
pub struct OpenRouterAgentTurnRuntime {
    manager: AcpAgentManagerHandle,
    session_id: String,
}

impl OpenRouterAgentTurnRuntime {
    #[must_use]
    pub fn new(manager: AcpAgentManagerHandle, session_id: impl Into<String>) -> Self {
        Self {
            manager,
            session_id: session_id.into(),
        }
    }

    /// Load the live process snapshot and refuse a turn from another session.
    ///
    /// Mirrors the Codex adapter's session-scope guard: the correlation id is
    /// the ACP logical id, so a caller cannot read or cancel a turn that
    /// belongs to a different Harness session.
    fn bound_snapshot(&self, id: &AgentTurnId) -> Result<AcpAgentSnapshot, CliError> {
        let snapshot = self.manager.get(id.as_str())?;
        if snapshot.session_id != self.session_id {
            return Err(CliErrorKind::session_scope_denied(format!(
                "OpenRouter turn '{id}' does not belong to session '{}'",
                self.session_id
            ))
            .into());
        }
        Ok(snapshot)
    }

    /// Read the live turn state the supervisor assembled for this ACP session.
    ///
    /// Returns `None` once the shim disconnects, because `inspect` drops
    /// disconnected sessions and the in-memory state goes with them.
    fn session_state(&self, id: &AgentTurnId) -> Result<Option<AcpAgentSessionState>, CliError> {
        Ok(self
            .manager
            .inspect(Some(&self.session_id))?
            .agents
            .into_iter()
            .find(|agent| agent.acp_id == id.as_str())
            .and_then(|agent| agent.session_state))
    }
}

#[async_trait]
impl AgentTurnRuntime for OpenRouterAgentTurnRuntime {
    fn runtime(&self) -> &'static str {
        OPENROUTER_RUNTIME
    }

    async fn start(&self, request: AgentTurnRequest) -> Result<AgentTurnId, CliError> {
        let request = request.into_validated()?;
        let start_request = openrouter_start_request(&request);
        let snapshot = self.manager.start(&self.session_id, &start_request)?;
        AgentTurnId::new(snapshot.acp_id)
    }

    async fn status(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        let snapshot = self.bound_snapshot(id)?;
        if let Some(state) = self.session_state(id)? {
            if let Some(failure) = &state.last_turn_failure {
                return Ok(turn_status_from_failure(failure));
            }
            if state.last_turn_result.is_some() {
                return Ok(AgentTurnStatus::Completed);
            }
        }
        Ok(live_turn_status(&snapshot.status))
    }

    async fn result(&self, id: &AgentTurnId) -> Result<Option<AgentTurnResult>, CliError> {
        self.bound_snapshot(id)?;
        let Some(state) = self.session_state(id)? else {
            return Ok(None);
        };
        if state.last_turn_failure.is_some() {
            return Ok(None);
        }
        let effective_model = openrouter_effective_model(&state);
        let Some(result) = state.last_turn_result else {
            return Ok(None);
        };
        Ok(Some(AgentTurnResult {
            correlation_id: id.clone(),
            report: result.report,
            stop_reason: result.stop_reason,
            requested_model: None,
            effective_model,
            source_revision: None,
        }))
    }

    async fn failure(&self, id: &AgentTurnId) -> Result<Option<AgentTurnFailure>, CliError> {
        let snapshot = self.bound_snapshot(id)?;
        if let Some(state) = self.session_state(id)? {
            return Ok(state.last_turn_failure);
        }
        Ok(disconnect_turn_failure(&snapshot.status))
    }

    async fn cancel(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        let snapshot = self.bound_snapshot(id)?;
        // Idempotent: a turn that already reached a terminal live state keeps
        // it, so a completed turn's result stays readable instead of being
        // stopped out from under a later `result` call.
        if let Some(state) = self.session_state(id)? {
            if let Some(failure) = &state.last_turn_failure {
                return Ok(turn_status_from_failure(failure));
            }
            if state.last_turn_result.is_some() {
                return Ok(AgentTurnStatus::Completed);
            }
        } else if is_terminal_process(&snapshot.status) {
            // The shim already disconnected: stopping it is a no-op, so report
            // the same terminal status `status`/`failure` would rather than
            // masking the real outcome as a cancellation.
            return Ok(live_turn_status(&snapshot.status));
        }
        self.manager.stop(id.as_str())?;
        Ok(AgentTurnStatus::Cancelled)
    }
}

/// Build the ACP start request for one report turn.
///
/// A report turn always opens a fresh ACP session (`resume_disabled`) so its
/// outcome is not contaminated by a prior turn's transcript.
fn openrouter_start_request(request: &ValidatedAgentTurnRequest) -> AcpAgentStartRequest {
    AcpAgentStartRequest {
        agent: OPENROUTER_RUNTIME.to_owned(),
        name: Some("OpenRouter report turn".to_owned()),
        prompt: Some(request.prompt.clone()),
        model: request.requested_model.clone(),
        resume_disabled: true,
        ..AcpAgentStartRequest::default()
    }
}

/// Effective model the shim ran, read from the advertised `model` config
/// option; `None` until `session/new` reports it.
fn openrouter_effective_model(state: &AcpAgentSessionState) -> Option<String> {
    state
        .config_options
        .iter()
        .find(|option| option.id == MODEL_CONFIG_OPTION_ID)
        .map(|option| option.current_value.clone())
}

fn turn_status_from_failure(failure: &AgentTurnFailure) -> AgentTurnStatus {
    if failure.category == AgentTurnFailureCategory::Cancelled {
        AgentTurnStatus::Cancelled
    } else {
        AgentTurnStatus::Failed
    }
}

/// Map the live ACP process status to a turn status when the session carries no
/// terminal turn outcome yet.
fn live_turn_status(status: &AgentStatus) -> AgentTurnStatus {
    match status {
        AgentStatus::Active | AgentStatus::Idle | AgentStatus::AwaitingReview => {
            AgentTurnStatus::Running
        }
        AgentStatus::Disconnected { reason, .. } if is_cancellation(reason) => {
            AgentTurnStatus::Cancelled
        }
        AgentStatus::Disconnected { .. } | AgentStatus::Removed => AgentTurnStatus::Failed,
    }
}

/// Synthesize a terminal failure for a shim that disconnected before its turn
/// state could be observed. A live session (`None` reason path) reports no
/// failure here; its outcome is read from `last_turn_failure` instead.
fn disconnect_turn_failure(status: &AgentStatus) -> Option<AgentTurnFailure> {
    let AgentStatus::Disconnected { reason, .. } = status else {
        return None;
    };
    let failure = if is_cancellation(reason) {
        AgentTurnFailure::cancelled(format!(
            "OpenRouter turn cancelled ({})",
            reason.log_label()
        ))
    } else if matches!(reason, DisconnectReason::AuthRequired) {
        AgentTurnFailure::new(
            AgentTurnFailureCategory::Authentication,
            AgentTurnFailureStage::Execution,
            "OpenRouter agent requires authentication before it can run a turn",
        )
    } else {
        AgentTurnFailure::new(
            AgentTurnFailureCategory::Transport,
            AgentTurnFailureStage::Execution,
            format!(
                "OpenRouter agent disconnected before completing the turn ({})",
                reason.log_label()
            ),
        )
    };
    Some(failure)
}

/// Whether the ACP process itself has reached a terminal state, meaning its
/// live turn state is already gone from `inspect`.
const fn is_terminal_process(status: &AgentStatus) -> bool {
    matches!(
        status,
        AgentStatus::Disconnected { .. } | AgentStatus::Removed
    )
}

const fn is_cancellation(reason: &DisconnectReason) -> bool {
    matches!(
        reason,
        DisconnectReason::SessionStopped | DisconnectReason::UserCancelled
    )
}

#[cfg(all(test, feature = "daemon-runtime"))]
mod tests;
