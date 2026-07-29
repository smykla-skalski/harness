use super::*;
use crate::PlanApprovalBlockReason;
use crate::types::ExternalRefProvider;

fn approved_write_item(kind: TaskBoardWorkflowKind, mode: AgentMode) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        format!("{kind:?}-{mode:?}"),
        "Ship write workflow".into(),
        "Preserve durable evidence".into(),
        "2026-07-18T10:00:00Z".into(),
    );
    item.workflow_kind = kind;
    item.agent_mode = mode;
    item.planning.summary = Some("Implement the approved plan".into());
    item.planning.approved_by = Some("operator".into());
    item.planning.approved_at = Some("2026-07-18T10:05:00Z".into());
    item
}

fn imported_pull_request_item(kind: TaskBoardWorkflowKind) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        format!("imported-{kind:?}"),
        "Imported pull request".into(),
        "Discovered from a provider".into(),
        "2026-07-20T10:00:00Z".into(),
    );
    item.workflow_kind = kind;
    item.imported_from_provider = Some(ExternalRefProvider::GitHub);
    // The import records a plan summary but never an approver, exactly the
    // shape that used to strand these tickets on the plan-approval gate.
    item.planning.summary = Some("Handle the imported pull request".into());
    item.agent_mode = kind
        .imported_admission_agent_mode()
        .expect("a pull-request kind resolves an admission mode");
    item
}

#[test]
fn imported_pull_requests_dispatch_from_todo_without_a_second_approval() {
    for kind in [
        TaskBoardWorkflowKind::PR_REVIEW,
        TaskBoardWorkflowKind::PR_FIX,
        TaskBoardWorkflowKind::PR_FIX_REVIEW,
    ] {
        let item = imported_pull_request_item(kind);
        let plan = build_dispatch_plan(&item);
        assert_eq!(
            plan.readiness,
            DispatchReadiness::Ready,
            "{kind:?} must be dispatch-ready straight from Todo"
        );
    }
}

fn assert_ready_with_mode(kind: TaskBoardWorkflowKind, mode: AgentMode) {
    let plan = build_dispatch_plan(&imported_pull_request_item(kind));
    assert_eq!(plan.readiness, DispatchReadiness::Ready, "{kind:?} readiness");
    assert_eq!(plan.worker.mode, mode, "{kind:?} worker mode");
}

#[test]
fn imported_review_dispatches_read_only_while_dependency_update_writes() {
    assert_ready_with_mode(TaskBoardWorkflowKind::PR_REVIEW, AgentMode::Evaluate);
    assert_ready_with_mode(TaskBoardWorkflowKind::PR_FIX, AgentMode::Headless);
    // The combined ticket keeps both intents and its write mode.
    let combined = TaskBoardWorkflowKind::PR_FIX_REVIEW;
    assert!(combined.has_dependency_update_intent());
    assert!(combined.has_review_request_intent());
    assert_ready_with_mode(combined, AgentMode::Headless);
}

#[test]
fn non_pull_request_items_still_require_plan_approval() {
    let mut item = TaskBoardItem::new(
        "plain-task".into(),
        "Plain task".into(),
        "body".into(),
        "2026-07-20T10:00:00Z".into(),
    );
    item.planning.summary = Some("Do the work".into());

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
fn write_workflows_block_non_headless_modes_before_reservation() {
    for kind in [
        TaskBoardWorkflowKind::DefaultTask,
        TaskBoardWorkflowKind::PR_FIX,
    ] {
        for mode in [
            AgentMode::Interactive,
            AgentMode::Planning,
            AgentMode::Evaluate,
        ] {
            let plan = build_dispatch_plan(&approved_write_item(kind, mode));
            assert!(
                matches!(plan.readiness, DispatchReadiness::Blocked { .. }),
                "{kind:?}/{mode:?} must be rejected before admission reservation"
            );
        }
    }
}

#[test]
fn write_workflows_keep_headless_dispatch_ready() {
    for kind in [
        TaskBoardWorkflowKind::DefaultTask,
        TaskBoardWorkflowKind::PR_FIX,
    ] {
        let plan = build_dispatch_plan(&approved_write_item(kind, AgentMode::Headless));
        assert_eq!(plan.readiness, DispatchReadiness::Ready);
    }
}
