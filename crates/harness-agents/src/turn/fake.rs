use std::collections::{BTreeMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};

use async_trait::async_trait;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::{AgentTurnId, AgentTurnRequest, AgentTurnResult, AgentTurnRuntime, AgentTurnStatus};

#[derive(Debug, Clone)]
pub enum FakeAgentTurnPlan {
    Complete { report: String, stop_reason: String },
    Fail,
}

impl FakeAgentTurnPlan {
    #[must_use]
    pub fn completed(report: impl Into<String>, stop_reason: impl Into<String>) -> Self {
        Self::Complete {
            report: report.into(),
            stop_reason: stop_reason.into(),
        }
    }

    #[must_use]
    pub const fn fail() -> Self {
        Self::Fail
    }
}

#[derive(Debug)]
struct FakeAgentTurn {
    status: AgentTurnStatus,
    plan: FakeAgentTurnPlan,
    requested_model: Option<String>,
    result: Option<AgentTurnResult>,
}

#[derive(Debug, Default)]
struct FakeAgentTurnState {
    planned: VecDeque<FakeAgentTurnPlan>,
    turns: BTreeMap<AgentTurnId, FakeAgentTurn>,
}

#[derive(Debug)]
pub struct FakeAgentTurnRuntime {
    next_id: AtomicU64,
    state: Mutex<FakeAgentTurnState>,
}

impl FakeAgentTurnRuntime {
    #[must_use]
    pub fn new(plans: impl IntoIterator<Item = FakeAgentTurnPlan>) -> Self {
        Self {
            next_id: AtomicU64::new(1),
            state: Mutex::new(FakeAgentTurnState {
                planned: plans.into_iter().collect(),
                turns: BTreeMap::new(),
            }),
        }
    }

    /// Advance one deterministic lifecycle step.
    ///
    /// # Errors
    /// Returns `CliError` when the correlation identifier is unknown.
    pub fn advance(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        let mut state = self.lock_state()?;
        let turn = state.turns.get_mut(id).ok_or_else(|| unknown_turn(id))?;
        match turn.status {
            AgentTurnStatus::Queued => turn.status = AgentTurnStatus::Running,
            AgentTurnStatus::Running => match &turn.plan {
                FakeAgentTurnPlan::Complete {
                    report,
                    stop_reason,
                } => {
                    turn.status = AgentTurnStatus::Completed;
                    turn.result = Some(AgentTurnResult {
                        correlation_id: id.clone(),
                        report: report.clone(),
                        stop_reason: stop_reason.clone(),
                        requested_model: turn.requested_model.clone(),
                        effective_model: turn.requested_model.clone(),
                    });
                }
                FakeAgentTurnPlan::Fail => turn.status = AgentTurnStatus::Failed,
            },
            AgentTurnStatus::Completed | AgentTurnStatus::Failed | AgentTurnStatus::Cancelled => {}
        }
        Ok(turn.status)
    }

    fn lock_state(&self) -> Result<MutexGuard<'_, FakeAgentTurnState>, CliError> {
        self.state.lock().map_err(|_| {
            CliError::from(CliErrorKind::workflow_io(
                "fake agent turn state lock poisoned",
            ))
        })
    }
}

#[async_trait]
impl AgentTurnRuntime for FakeAgentTurnRuntime {
    fn runtime(&self) -> &'static str {
        "fake"
    }

    async fn start(&self, request: AgentTurnRequest) -> Result<AgentTurnId, CliError> {
        let mut state = self.lock_state()?;
        let plan = state.planned.pop_front().ok_or_else(|| {
            CliError::from(CliErrorKind::invalid_transition(
                "fake agent runtime has no planned turn",
            ))
        })?;
        let sequence = self.next_id.fetch_add(1, Ordering::Relaxed);
        let id = AgentTurnId::new(format!("fake-turn-{sequence}"))?;
        state.turns.insert(
            id.clone(),
            FakeAgentTurn {
                status: AgentTurnStatus::Queued,
                plan,
                requested_model: request.requested_model,
                result: None,
            },
        );
        Ok(id)
    }

    async fn status(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        self.lock_state()?
            .turns
            .get(id)
            .map(|turn| turn.status)
            .ok_or_else(|| unknown_turn(id))
    }

    async fn result(&self, id: &AgentTurnId) -> Result<Option<AgentTurnResult>, CliError> {
        self.lock_state()?
            .turns
            .get(id)
            .map(|turn| turn.result.clone())
            .ok_or_else(|| unknown_turn(id))
    }

    async fn cancel(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        let mut state = self.lock_state()?;
        let turn = state.turns.get_mut(id).ok_or_else(|| unknown_turn(id))?;
        if !turn.status.is_terminal() {
            turn.status = AgentTurnStatus::Cancelled;
            turn.result = None;
        }
        Ok(turn.status)
    }
}

fn unknown_turn(id: &AgentTurnId) -> CliError {
    CliErrorKind::invalid_transition(format!("unknown agent turn '{id}'")).into()
}
