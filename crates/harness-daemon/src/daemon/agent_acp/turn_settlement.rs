//! One decision point for the terminal outcome an observed ACP session state
//! represents, shared by every path that settles a durable agent-turn run.
//!
//! A provider turn can fail and then detach before the next reconciliation
//! poll. `inspect` hides a disconnected session, so a caller that treats "not
//! attached" as the outcome overwrites the provider's own error with a generic
//! detachment message and loses the category the detail classifies to. Settling
//! from the last observed state instead keeps the real cause.

use crate::daemon::db::AgentTurnRunStatus;

use super::{
    AcpAgentSessionState, AgentTurnFailureCategory, PROVIDER_EFFECTIVE_MODEL_CONFIG_OPTION_ID,
};

/// Recorded only when a turn's provider session is gone and never reported an
/// outcome. Operators and reconciliation tests match on this exact wording.
pub(crate) const DETACHED_TURN_ERROR: &str = "provider turn is no longer attached to this daemon";

/// The durable terminal columns one observed session state settles to.
#[derive(Debug)]
pub(crate) struct AgentTurnSettlement {
    pub(crate) status: AgentTurnRunStatus,
    pub(crate) actual_model: Option<String>,
    pub(crate) report: Option<String>,
    pub(crate) stop_reason: Option<String>,
    pub(crate) error: Option<String>,
}

impl AgentTurnSettlement {
    /// The terminal outcome this state carries, or `None` while the turn is
    /// still running.
    ///
    /// A failure outranks a result, matching how live turn status reads the
    /// same state. Starting a turn clears both, so the two are never set
    /// together; if they ever were, a recorded failure is the one that must not
    /// be masked.
    pub(crate) fn from_session_state(state: &AcpAgentSessionState) -> Option<Self> {
        let actual_model = effective_model(state);
        if let Some(failure) = state.last_turn_failure.as_ref() {
            let cancelled = failure.category == AgentTurnFailureCategory::Cancelled;
            return Some(Self {
                status: if cancelled {
                    AgentTurnRunStatus::Cancelled
                } else {
                    AgentTurnRunStatus::Failed
                },
                actual_model,
                report: state.last_turn_partial_output.clone(),
                stop_reason: cancelled.then(|| failure.detail.clone()),
                error: (!cancelled).then(|| failure.detail.clone()),
            });
        }
        let result = state.last_turn_result.as_ref()?;
        Some(Self {
            status: AgentTurnRunStatus::Completed,
            actual_model,
            report: Some(result.report.clone()),
            stop_reason: Some(result.stop_reason.clone()),
            error: None,
        })
    }

    /// The outcome for a turn whose provider session vanished without ever
    /// reporting one.
    pub(crate) fn detached() -> Self {
        Self {
            status: AgentTurnRunStatus::Failed,
            actual_model: None,
            report: None,
            stop_reason: None,
            error: Some(DETACHED_TURN_ERROR.to_owned()),
        }
    }
}

/// The model the provider actually served, as opposed to the one requested.
fn effective_model(state: &AcpAgentSessionState) -> Option<String> {
    state
        .config_options
        .iter()
        .find(|option| option.id == PROVIDER_EFFECTIVE_MODEL_CONFIG_OPTION_ID)
        .map(|option| option.current_value.clone())
}

#[cfg(test)]
#[path = "turn_settlement_tests.rs"]
mod tests;
