use super::*;

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

#[test]
fn write_workflows_block_non_headless_modes_before_reservation() {
    for kind in [
        TaskBoardWorkflowKind::DefaultTask,
        TaskBoardWorkflowKind::PrFix,
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
        TaskBoardWorkflowKind::PrFix,
    ] {
        let plan = build_dispatch_plan(&approved_write_item(kind, AgentMode::Headless));
        assert_eq!(plan.readiness, DispatchReadiness::Ready);
    }
}
