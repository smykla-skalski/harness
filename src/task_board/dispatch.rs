use serde::{Deserialize, Serialize};

use crate::session::types::{TaskSeverity, TaskSource};

use super::planning::{PlanApprovalBlockReason, PlanApprovalGate, approval_gate};
use super::policy::{
    BuiltInPolicyGate, PolicyAction, PolicyDecision, PolicyGate, PolicyInput, PolicySubject,
};
use super::types::{AgentMode, ExternalRef, TaskBoardItem, TaskBoardPriority, TaskBoardStatus};

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
    pub policy: PolicyDecision,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DispatchExecutionSummary {
    pub plans: Vec<DispatchPlan>,
    pub applied: Vec<DispatchAppliedTask>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DispatchAppliedTask {
    pub board_item_id: String,
    pub session_id: String,
    pub work_item_id: String,
    pub item: TaskBoardItem,
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
    AlreadyLinked { work_item_id: String },
    Deleted,
    PlanApproval { reason: PlanApprovalBlockReason },
    Policy { decision: PolicyDecision },
    Status { status: TaskBoardStatus },
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
}

impl DispatchExecutionSummary {
    #[must_use]
    pub fn dry_run(plans: Vec<DispatchPlan>) -> Self {
        Self {
            plans,
            applied: Vec::new(),
        }
    }
}

#[must_use]
pub fn build_dispatch_plan(item: &TaskBoardItem) -> DispatchPlan {
    let policy = dispatch_policy(item);
    DispatchPlan {
        board_item_id: item.id.clone(),
        readiness: readiness(item, &policy),
        session: session_intent(item),
        task: task_creation_intent(item),
        worker: WorkerIntent {
            mode: item.agent_mode,
        },
        reviewer: reviewer_intent(),
        evaluator: evaluator_intent(),
        policy,
    }
}

#[must_use]
pub fn build_dispatch_plans(items: &[TaskBoardItem]) -> Vec<DispatchPlan> {
    items.iter().map(build_dispatch_plan).collect()
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

fn dispatch_policy(item: &TaskBoardItem) -> PolicyDecision {
    let mut input = PolicyInput::new(PolicyAction::SpawnAgent);
    input.subject = PolicySubject {
        task_board_item_id: Some(item.id.clone()),
        session_id: item.session_id.clone(),
        repository: item.project_id.clone(),
        ..PolicySubject::default()
    };
    BuiltInPolicyGate::default().evaluate(&input)
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
mod tests {
    use super::*;
    use crate::task_board::planning::{approve_plan, submit_plan};
    use crate::task_board::types::ExternalRefProvider;

    fn ready_item() -> TaskBoardItem {
        let item = TaskBoardItem::new(
            "task-1".into(),
            "Ship dispatch".into(),
            "Create planning-only dispatch data.".into(),
            "2026-05-14T00:00:00Z".into(),
        );
        let item = submit_plan(&item, "Use session task creation.").apply_to(&item);
        approve_plan(&item, "lead", "2026-05-14T01:00:00Z").apply_to(&item)
    }

    #[test]
    fn ready_dispatch_plan_maps_board_fields_to_session_task_intent() {
        let mut item = ready_item();
        item.priority = TaskBoardPriority::Critical;
        item.agent_mode = AgentMode::Interactive;
        item.project_id = Some("project-1".into());
        item.tags = vec!["cli".into(), "board".into()];
        item.external_refs = vec![ExternalRef {
            provider: ExternalRefProvider::GitHub,
            external_id: "123".into(),
            url: Some("https://example.invalid/123".into()),
        }];

        let plan = build_dispatch_plan(&item);

        assert!(plan.is_ready());
        assert_eq!(
            plan.session,
            SessionIntent::Create {
                title: "Ship dispatch".into(),
                context: Some("Create planning-only dispatch data.".into()),
                project_id: Some("project-1".into())
            }
        );
        assert_eq!(plan.task.severity, TaskSeverity::Critical);
        assert_eq!(
            plan.task.suggested_fix.as_deref(),
            Some("Use session task creation.")
        );
        assert_eq!(plan.task.tags, ["cli", "board"]);
        assert_eq!(plan.worker.mode, AgentMode::Interactive);
        assert_eq!(plan.reviewer.suggested_persona, REVIEWER_PERSONA);
        assert_eq!(plan.evaluator.mode, AgentMode::Evaluate);
        assert!(plan.policy.is_allow());
    }

    #[test]
    fn dispatch_plan_blocks_without_plan_approval() {
        let item = TaskBoardItem::new(
            "task-1".into(),
            "Ship dispatch".into(),
            "body".into(),
            "2026-05-14T00:00:00Z".into(),
        );
        let item = submit_plan(&item, "plan").apply_to(&item);

        let plan = build_dispatch_plan(&item);

        assert_eq!(
            plan.readiness,
            DispatchReadiness::Blocked {
                reason: DispatchBlockReason::PlanApproval {
                    reason: PlanApprovalBlockReason::MissingApprover
                }
            }
        );
    }

    #[test]
    fn dispatch_plan_targets_existing_session_when_linked() {
        let mut item = ready_item();
        item.session_id = Some("session-1".into());

        let plan = build_dispatch_plan(&item);

        assert_eq!(
            plan.session,
            SessionIntent::Existing {
                session_id: "session-1".into()
            }
        );
    }
}
