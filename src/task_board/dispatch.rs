use std::collections::HashMap;
#[cfg(test)]
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::session::types::{TaskSeverity, TaskSource};

#[cfg(test)]
use super::default_board_root;
#[cfg(not(test))]
use super::machines::Machine;
#[cfg(test)]
use super::machines::{Machine, MachineRegistry};
use super::planning::{PlanApprovalBlockReason, PlanApprovalGate, approval_gate};
use super::policy::{PolicyApprovalGrant, PolicyDecision};
#[cfg(test)]
use super::store::TaskBoardStore;
use super::types::{AgentMode, ExternalRef, TaskBoardItem, TaskBoardPriority, TaskBoardStatus};
use super::{
    TaskBoardPlanApprovalBinding, TaskBoardPlanningResult, TaskBoardPullRequestIdentity,
    TaskBoardReadOnlyRunContext, TaskBoardResolvedReviewer, TaskBoardWorkflowKind,
};

#[path = "dispatch_readiness.rs"]
mod readiness;
use readiness::{blocked, readiness};

#[path = "dispatch_lifecycle.rs"]
mod lifecycle;
pub use lifecycle::{
    DispatchLifecycle, DispatchLifecyclePhase, DispatchLifecycleStatus, DispatchLifecycleStep,
    DispatchNativeSignal,
};

const REVIEWER_PERSONA: &str = "code-reviewer";
const REVIEWER_CONSENSUS: u8 = 2;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DispatchPlan {
    pub board_item_id: String,
    #[serde(default)]
    pub rendered_prompt: String,
    pub readiness: DispatchReadiness,
    pub session: SessionIntent,
    pub task: TaskCreationIntent,
    pub worker: WorkerIntent,
    pub reviewer: ReviewerIntent,
    pub evaluator: EvaluatorIntent,
    pub lifecycle: DispatchLifecycle,
    pub policy: PolicyDecision,
    /// Id of the recorded policy decision that produced `policy`, threaded into
    /// reservation so the board workflow stores the real decision id instead of
    /// an unrelated random trace. `None` when the built-in fallback gate decided
    /// (no decision is recorded on that path).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_decision_id: Option<String>,
    /// Id of the durable approval grant this dispatch will consume at reservation.
    /// Set only when an approved live grant matched the spawn evaluation and the
    /// decision allowed; the reservation transaction consumes it one-shot so a
    /// re-dispatch needs a fresh approval. `None` on every non-approval path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub consumed_approval_grant_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DispatchExecutionSummary {
    pub plans: Vec<DispatchPlan>,
    pub applied: Vec<DispatchAppliedTask>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failures: Vec<DispatchFailure>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DispatchAppliedTask {
    pub board_item_id: String,
    pub session_id: String,
    pub work_item_id: String,
    pub lifecycle: DispatchLifecycle,
    pub item: TaskBoardItem,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_only_workflow: Option<TaskBoardReadOnlyWorkflowLaunch>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub write_workflow: Option<Box<TaskBoardWriteWorkflowLaunch>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardReadOnlyWorkflowLaunch {
    pub workflow_kind: TaskBoardWorkflowKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_repository: Option<String>,
    pub configuration_revision: u64,
    pub policy_version: String,
    pub resolved_reviewers: TaskBoardResolvedReviewer,
    pub source_item_revision: i64,
    pub prepared_item_revision: i64,
    #[serde(default)]
    pub run_context: TaskBoardReadOnlyRunContext,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pull_request: Option<TaskBoardPullRequestIdentity>,
    pub exact_head_revision: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardWriteWorkflowLaunch {
    pub workflow_kind: TaskBoardWorkflowKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_repository: Option<String>,
    pub configuration_revision: u64,
    pub policy_version: String,
    pub resolved_reviewers: TaskBoardResolvedReviewer,
    pub source_item_revision: i64,
    pub prepared_item_revision: i64,
    #[serde(default)]
    pub task_id: String,
    #[serde(default)]
    pub run_context: TaskBoardReadOnlyRunContext,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pull_request: Option<TaskBoardPullRequestIdentity>,
    pub base_head_revision: String,
    pub planning_result: TaskBoardPlanningResult,
    pub plan_approval: TaskBoardPlanApprovalBinding,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DispatchFailure {
    pub board_item_id: String,
    pub kind: DispatchFailureKind,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DispatchFailureKind {
    CreateSession,
    CreateTask,
    LinkItem,
    WorkerSpawnFailed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum DispatchReadiness {
    Ready,
    Blocked { reason: DispatchBlockReason },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DispatchBlockReason {
    AlreadyLinked {
        work_item_id: String,
    },
    Deleted,
    MachineMismatch {
        required: Vec<String>,
        declared: Vec<String>,
    },
    PlanApproval {
        reason: PlanApprovalBlockReason,
    },
    Policy {
        decision: PolicyDecision,
    },
    Status {
        status: TaskBoardStatus,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SessionIntent {
    Existing {
        session_id: String,
    },
    Create {
        title: String,
        context: Option<String>,
        project_id: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskCreationIntent {
    pub title: String,
    pub context: Option<String>,
    pub severity: TaskSeverity,
    pub suggested_fix: Option<String>,
    pub source: TaskSource,
    pub tags: Vec<String>,
    pub external_refs: Vec<ExternalRef>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerIntent {
    pub mode: AgentMode,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewerIntent {
    pub phase: FollowUpPhase,
    pub suggested_persona: String,
    pub required_consensus: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EvaluatorIntent {
    pub phase: FollowUpPhase,
    pub mode: AgentMode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FollowUpPhase {
    AfterWorkerReview,
}

impl DispatchPlan {
    #[must_use]
    pub const fn is_ready(&self) -> bool {
        matches!(self.readiness, DispatchReadiness::Ready)
    }

    #[must_use]
    pub fn applied_lifecycle(&self) -> DispatchLifecycle {
        self.lifecycle.applied()
    }
}

impl DispatchExecutionSummary {
    #[must_use]
    pub fn dry_run(plans: Vec<DispatchPlan>) -> Self {
        Self {
            plans,
            applied: Vec::new(),
            failures: Vec::new(),
        }
    }
}

#[must_use]
#[cfg(test)]
pub fn build_dispatch_plan(item: &TaskBoardItem) -> DispatchPlan {
    build_dispatch_plan_with_policy_root(item, &default_board_root())
}

#[must_use]
#[cfg(test)]
pub fn build_dispatch_plan_with_policy_root(
    item: &TaskBoardItem,
    policy_root: &Path,
) -> DispatchPlan {
    let (policy, policy_decision_id) = dispatch_policy(item, policy_root);
    build_dispatch_plan_with_decision(item, policy, policy_decision_id, None)
}

fn build_dispatch_plan_with_decision(
    item: &TaskBoardItem,
    policy: PolicyDecision,
    policy_decision_id: Option<String>,
    consumed_approval_grant_id: Option<String>,
) -> DispatchPlan {
    let worker = WorkerIntent {
        mode: item.agent_mode,
    };
    let reviewer = reviewer_intent();
    let evaluator = evaluator_intent();
    DispatchPlan {
        board_item_id: item.id.clone(),
        rendered_prompt: super::plan_worker_prompt(item),
        readiness: readiness(item, &policy),
        session: session_intent(item),
        task: task_creation_intent(item),
        lifecycle: DispatchLifecycle::planned(&worker, &reviewer, &evaluator),
        worker,
        reviewer,
        evaluator,
        policy,
        policy_decision_id,
        consumed_approval_grant_id,
    }
}

#[must_use]
pub(crate) fn build_dispatch_plans_with_policy(
    items: &[TaskBoardItem],
    policy: Option<(&str, &super::policy_graph::PolicyGraph)>,
    evaluated_at: Option<&str>,
    switches: SpawnGateSwitches,
    grants: &HashMap<String, PolicyApprovalGrant>,
) -> Vec<DispatchPlan> {
    items
        .iter()
        .map(|item| {
            let grant = grants.get(&item.id);
            let (decision, decision_id) = dispatch_policy_from_graph(
                item,
                policy,
                evaluated_at.map(str::to_owned),
                switches,
                grant,
            );
            let consumed = consumed_grant_id(grant, &decision);
            build_dispatch_plan_with_decision(item, decision, decision_id, consumed)
        })
        .collect()
}

#[must_use]
#[cfg(test)]
pub fn build_dispatch_plans(items: &[TaskBoardItem]) -> Vec<DispatchPlan> {
    items.iter().map(build_dispatch_plan).collect()
}

#[must_use]
#[cfg(test)]
pub fn build_dispatch_plans_with_policy_root(
    items: &[TaskBoardItem],
    policy_root: &Path,
) -> Vec<DispatchPlan> {
    items
        .iter()
        .map(|item| build_dispatch_plan_with_policy_root(item, policy_root))
        .collect()
}

/// Partition items by whether the local machine's declared `project_types`
/// accept them. The local machine record is looked up from `board`; if it
/// cannot be loaded, every item is kept (fail-open) so dispatch on an
/// unregistered host behaves like a single-machine setup.
#[must_use]
#[cfg(test)]
pub fn filter_for_local_machine(
    items: Vec<TaskBoardItem>,
    board: &TaskBoardStore,
) -> (Vec<TaskBoardItem>, Vec<(TaskBoardItem, Machine)>) {
    let Ok(machine) = MachineRegistry::new(board.root().to_path_buf()).ensure_local() else {
        return (items, Vec::new());
    };
    let mut kept = Vec::with_capacity(items.len());
    let mut rejected = Vec::new();
    for item in items {
        if machine.accepts_any(&item.target_project_types) {
            kept.push(item);
        } else {
            rejected.push((item, machine.clone()));
        }
    }
    (kept, rejected)
}

/// Build a `Blocked { MachineMismatch }` plan for an item the local machine
/// refused. Surfaces the item's required `target_project_types` and the
/// machine's declared `project_types` so callers can show users why their
/// dispatch didn't reach this host. Defers to the configured policy
/// pipeline at `policy_root` for the plan's policy field so the response
/// still reflects what policy evaluation would have produced.
#[must_use]
#[cfg(test)]
pub fn machine_mismatch_plan_with_policy_root(
    item: &TaskBoardItem,
    machine: &Machine,
    policy_root: &Path,
) -> DispatchPlan {
    let worker = WorkerIntent {
        mode: item.agent_mode,
    };
    let reviewer = reviewer_intent();
    let evaluator = evaluator_intent();
    let (policy, policy_decision_id) = dispatch_policy(item, policy_root);
    DispatchPlan {
        board_item_id: item.id.clone(),
        rendered_prompt: super::plan_worker_prompt(item),
        readiness: blocked(DispatchBlockReason::MachineMismatch {
            required: item.target_project_types.clone(),
            declared: machine.project_types.clone(),
        }),
        session: session_intent(item),
        task: task_creation_intent(item),
        lifecycle: DispatchLifecycle::planned(&worker, &reviewer, &evaluator),
        worker,
        reviewer,
        evaluator,
        policy,
        policy_decision_id,
        consumed_approval_grant_id: None,
    }
}

#[must_use]
pub(crate) fn machine_mismatch_plan_with_policy(
    item: &TaskBoardItem,
    machine: &Machine,
    policy: Option<(&str, &super::policy_graph::PolicyGraph)>,
    evaluated_at: Option<&str>,
    switches: SpawnGateSwitches,
    grant: Option<&PolicyApprovalGrant>,
) -> DispatchPlan {
    let (decision, decision_id) = dispatch_policy_from_graph(
        item,
        policy,
        evaluated_at.map(str::to_owned),
        switches,
        grant,
    );
    let consumed = consumed_grant_id(grant, &decision);
    let mut plan = build_dispatch_plan_with_decision(item, decision, decision_id, consumed);
    plan.readiness = blocked(DispatchBlockReason::MachineMismatch {
        required: item.target_project_types.clone(),
        declared: machine.project_types.clone(),
    });
    plan
}

#[path = "dispatch_spawn_policy.rs"]
mod spawn_policy;
pub use spawn_policy::SpawnGateSwitches;
#[cfg(test)]
use spawn_policy::dispatch_policy;
#[cfg(test)]
pub(crate) use spawn_policy::spawn_policy_input;
pub(crate) use spawn_policy::{consumed_grant_id, dispatch_policy_from_graph};

fn session_intent(item: &TaskBoardItem) -> SessionIntent {
    if let Some(session_id) = item.session_id.as_deref() {
        return SessionIntent::Existing {
            session_id: session_id.to_string(),
        };
    }
    SessionIntent::Create {
        title: item.title.clone(),
        context: non_empty(&item.body),
        project_id: item.project_id.clone(),
    }
}

fn task_creation_intent(item: &TaskBoardItem) -> TaskCreationIntent {
    TaskCreationIntent {
        title: item.title.clone(),
        context: non_empty(&item.body),
        severity: severity(item.priority),
        suggested_fix: item.planning.summary.clone(),
        source: TaskSource::Manual,
        tags: item.tags.clone(),
        external_refs: item.external_refs.clone(),
    }
}

fn reviewer_intent() -> ReviewerIntent {
    ReviewerIntent {
        phase: FollowUpPhase::AfterWorkerReview,
        suggested_persona: REVIEWER_PERSONA.to_string(),
        required_consensus: REVIEWER_CONSENSUS,
    }
}

const fn evaluator_intent() -> EvaluatorIntent {
    EvaluatorIntent {
        phase: FollowUpPhase::AfterWorkerReview,
        mode: AgentMode::Evaluate,
    }
}

const fn severity(priority: TaskBoardPriority) -> TaskSeverity {
    match priority {
        TaskBoardPriority::Low => TaskSeverity::Low,
        TaskBoardPriority::Medium => TaskSeverity::Medium,
        TaskBoardPriority::High => TaskSeverity::High,
        TaskBoardPriority::Critical => TaskSeverity::Critical,
    }
}

fn non_empty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

#[cfg(test)]
#[path = "dispatch_tests.rs"]
mod tests;
#[cfg(test)]
#[path = "dispatch_write_workflow_tests.rs"]
mod write_workflow_tests;
