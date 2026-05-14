use serde::{Deserialize, Serialize};

use crate::session::service::SPAWN_REVIEWER_COMMAND;
use crate::task_board::types::AgentMode;

use super::{EvaluatorIntent, ReviewerIntent, WorkerIntent};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DispatchLifecycle {
    pub worker: DispatchLifecycleStep,
    pub reviewer: DispatchLifecycleStep,
    pub evaluator: DispatchLifecycleStep,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DispatchLifecycleStep {
    pub phase: DispatchLifecyclePhase,
    pub status: DispatchLifecycleStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<AgentMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suggested_persona: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required_consensus: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub native_signal: Option<DispatchNativeSignal>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DispatchLifecyclePhase {
    Worker,
    Reviewer,
    Evaluator,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DispatchLifecycleStatus {
    Planned,
    SessionTaskLinked,
    WaitingForWorkerReview,
    WaitingForReviewCompletion,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DispatchNativeSignal {
    pub command: String,
    pub trigger_step: String,
}

impl DispatchLifecycle {
    #[must_use]
    pub fn planned(
        worker: &WorkerIntent,
        reviewer: &ReviewerIntent,
        evaluator: &EvaluatorIntent,
    ) -> Self {
        Self {
            worker: DispatchLifecycleStep::worker(worker.mode, DispatchLifecycleStatus::Planned),
            reviewer: DispatchLifecycleStep::reviewer(reviewer, DispatchLifecycleStatus::Planned),
            evaluator: DispatchLifecycleStep::evaluator(
                evaluator.mode,
                DispatchLifecycleStatus::Planned,
            ),
        }
    }

    #[must_use]
    pub fn applied(&self) -> Self {
        let mut lifecycle = self.clone();
        lifecycle.worker.status = DispatchLifecycleStatus::SessionTaskLinked;
        lifecycle.reviewer.status = DispatchLifecycleStatus::WaitingForWorkerReview;
        lifecycle.evaluator.status = DispatchLifecycleStatus::WaitingForReviewCompletion;
        lifecycle
    }
}

impl DispatchLifecycleStep {
    fn worker(mode: AgentMode, status: DispatchLifecycleStatus) -> Self {
        Self {
            phase: DispatchLifecyclePhase::Worker,
            status,
            mode: Some(mode),
            suggested_persona: None,
            required_consensus: None,
            native_signal: None,
        }
    }

    fn reviewer(intent: &ReviewerIntent, status: DispatchLifecycleStatus) -> Self {
        Self {
            phase: DispatchLifecyclePhase::Reviewer,
            status,
            mode: None,
            suggested_persona: Some(intent.suggested_persona.clone()),
            required_consensus: Some(intent.required_consensus),
            native_signal: Some(DispatchNativeSignal {
                command: SPAWN_REVIEWER_COMMAND.to_string(),
                trigger_step: "submit_for_review".to_string(),
            }),
        }
    }

    fn evaluator(mode: AgentMode, status: DispatchLifecycleStatus) -> Self {
        Self {
            phase: DispatchLifecyclePhase::Evaluator,
            status,
            mode: Some(mode),
            suggested_persona: None,
            required_consensus: None,
            native_signal: None,
        }
    }
}
