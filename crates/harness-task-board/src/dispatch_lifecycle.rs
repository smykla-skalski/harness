//! Dispatch lifecycle wire types.
//!
//! Relocated to `harness_protocol::daemon::task_board::dispatch_lifecycle`
//! (#1145): pure data, needed there because `DispatchPlan` embeds
//! `DispatchLifecycle` directly. `DispatchLifecycle::applied()` (a pure field
//! mutation) moved with the type; `DispatchLifecycle::planned()` and its
//! private `worker`/`reviewer`/`evaluator` step builders could not, since
//! they read `harness_session::service::SPAWN_REVIEWER_COMMAND` and
//! `harness-protocol` cannot depend on `harness-session`, which itself
//! depends on `harness-protocol`. They became this free function instead;
//! `dispatch.rs`'s own `build_dispatch_plan_with_decision` now calls it in
//! place of `DispatchLifecycle::planned`, and so do `harness-daemon`'s two
//! external callers.
use harness_session::service::SPAWN_REVIEWER_COMMAND;

pub use harness_protocol::daemon::task_board::dispatch_lifecycle::{
    DispatchLifecycle, DispatchLifecyclePhase, DispatchLifecycleStatus, DispatchLifecycleStep,
    DispatchNativeSignal,
};

use crate::types::AgentMode;

use super::{EvaluatorIntent, ReviewerIntent, WorkerIntent};

#[must_use]
pub fn dispatch_lifecycle_planned(
    worker: &WorkerIntent,
    reviewer: &ReviewerIntent,
    evaluator: &EvaluatorIntent,
) -> DispatchLifecycle {
    DispatchLifecycle {
        worker: lifecycle_worker_step(worker.mode, DispatchLifecycleStatus::Planned),
        reviewer: lifecycle_reviewer_step(reviewer, DispatchLifecycleStatus::Planned),
        evaluator: lifecycle_evaluator_step(evaluator.mode, DispatchLifecycleStatus::Planned),
    }
}

fn lifecycle_worker_step(
    mode: AgentMode,
    status: DispatchLifecycleStatus,
) -> DispatchLifecycleStep {
    DispatchLifecycleStep {
        phase: DispatchLifecyclePhase::Worker,
        status,
        mode: Some(mode),
        suggested_persona: None,
        required_consensus: None,
        native_signal: None,
    }
}

fn lifecycle_reviewer_step(
    intent: &ReviewerIntent,
    status: DispatchLifecycleStatus,
) -> DispatchLifecycleStep {
    DispatchLifecycleStep {
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

fn lifecycle_evaluator_step(
    mode: AgentMode,
    status: DispatchLifecycleStatus,
) -> DispatchLifecycleStep {
    DispatchLifecycleStep {
        phase: DispatchLifecyclePhase::Evaluator,
        status,
        mode: Some(mode),
        suggested_persona: None,
        required_consensus: None,
        native_signal: None,
    }
}
