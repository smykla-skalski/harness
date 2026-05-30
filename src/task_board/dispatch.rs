use std::path::Path;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::session::types::{TaskSeverity, TaskSource};

use super::default_board_root;
use super::machines::{Machine, MachineRegistry};
use super::planning::{PlanApprovalBlockReason, PlanApprovalGate, approval_gate};
use super::policy::{
    BuiltInPolicyGate, PolicyAction, PolicyDecision, PolicyGate, PolicyInput, PolicySubject,
};
use super::policy_graph::{
    GraphPolicyGate, PolicyGraph, PolicyPipelineMode, PolicyPipelineStore, cached_gate_policy,
};
use super::store::TaskBoardStore;
use super::types::{AgentMode, ExternalRef, TaskBoardItem, TaskBoardPriority, TaskBoardStatus};

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
    pub readiness: DispatchReadiness,
    pub session: SessionIntent,
    pub task: TaskCreationIntent,
    pub worker: WorkerIntent,
    pub reviewer: ReviewerIntent,
    pub evaluator: EvaluatorIntent,
    pub lifecycle: DispatchLifecycle,
    pub policy: PolicyDecision,
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
pub fn build_dispatch_plan(item: &TaskBoardItem) -> DispatchPlan {
    build_dispatch_plan_with_policy_root(item, &default_board_root())
}

#[must_use]
pub fn build_dispatch_plan_with_policy_root(
    item: &TaskBoardItem,
    policy_root: &Path,
) -> DispatchPlan {
    let policy = dispatch_policy(item, policy_root);
    let worker = WorkerIntent {
        mode: item.agent_mode,
    };
    let reviewer = reviewer_intent();
    let evaluator = evaluator_intent();
    DispatchPlan {
        board_item_id: item.id.clone(),
        readiness: readiness(item, &policy),
        session: session_intent(item),
        task: task_creation_intent(item),
        lifecycle: DispatchLifecycle::planned(&worker, &reviewer, &evaluator),
        worker,
        reviewer,
        evaluator,
        policy,
    }
}

#[must_use]
pub fn build_dispatch_plans(items: &[TaskBoardItem]) -> Vec<DispatchPlan> {
    items.iter().map(build_dispatch_plan).collect()
}

#[must_use]
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
    DispatchPlan {
        board_item_id: item.id.clone(),
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
        policy: dispatch_policy(item, policy_root),
    }
}

fn readiness(item: &TaskBoardItem, policy: &PolicyDecision) -> DispatchReadiness {
    if item.is_deleted() {
        return blocked(DispatchBlockReason::Deleted);
    }
    if let Some(work_item_id) = item.work_item_id.as_deref() {
        return blocked(DispatchBlockReason::AlreadyLinked {
            work_item_id: work_item_id.to_string(),
        });
    }
    if let PlanApprovalGate::Blocked { reason } = approval_gate(item) {
        return blocked(DispatchBlockReason::PlanApproval { reason });
    }
    if item.status != TaskBoardStatus::Todo {
        return blocked(DispatchBlockReason::Status {
            status: item.status,
        });
    }
    if !policy.is_allow() {
        return blocked(DispatchBlockReason::Policy {
            decision: policy.clone(),
        });
    }
    DispatchReadiness::Ready
}

fn dispatch_policy(item: &TaskBoardItem, policy_root: &Path) -> PolicyDecision {
    let mut input = PolicyInput::new(PolicyAction::SpawnAgent);
    input.subject = PolicySubject {
        task_board_item_id: Some(item.id.clone()),
        session_id: item.session_id.clone(),
        repository: item.project_id.clone(),
        ..PolicySubject::default()
    };
    if let Some(document) = resolve_gate_policy(policy_root)
        && document.mode != PolicyPipelineMode::Draft
    {
        return GraphPolicyGate::new((*document).clone()).evaluate(&input);
    }
    BuiltInPolicyGate::default().evaluate(&input)
}

/// The active gating policy for `policy_root`: the warm process cache when
/// present, otherwise a cold read from the durable store. The cold read does
/// not populate the cache; the policy write path keeps the cache current.
fn resolve_gate_policy(policy_root: &Path) -> Option<Arc<PolicyGraph>> {
    cached_gate_policy(policy_root).or_else(|| {
        PolicyPipelineStore::new(policy_root.to_path_buf())
            .load_or_seed()
            .ok()
            .map(Arc::new)
    })
}

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

fn blocked(reason: DispatchBlockReason) -> DispatchReadiness {
    DispatchReadiness::Blocked { reason }
}

fn non_empty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

#[cfg(test)]
#[path = "dispatch_tests.rs"]
mod tests;
