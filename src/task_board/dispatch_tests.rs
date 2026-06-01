use super::*;
use crate::task_board::planning::{approve_plan, submit_plan};
use crate::task_board::policy::PolicyAction;
use crate::task_board::policy_graph::{
    PolicyCanvasWorkspace, PolicyGraph, PolicyGraphEdge, PolicyGraphEdgeCondition, PolicyGraphMode,
    PolicyGraphNodeKind, PolicyPipelinePromoteRequest, apply_promote, apply_save_draft,
    apply_simulate,
};
use crate::task_board::types::ExternalRefProvider;
use tempfile::tempdir;

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
        sync_state: None,
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
    assert_eq!(
        plan.lifecycle
            .reviewer
            .native_signal
            .as_ref()
            .map(|signal| (signal.command.as_str(), signal.trigger_step.as_str())),
        Some(("spawn_reviewer", "submit_for_review"))
    );
    assert!(plan.policy.is_allow());
}

#[test]
fn applied_lifecycle_preserves_follow_up_execution_order() {
    let plan = build_dispatch_plan(&ready_item());

    let lifecycle = plan.applied_lifecycle();

    assert_eq!(
        lifecycle.worker.status,
        DispatchLifecycleStatus::SessionTaskLinked
    );
    assert_eq!(
        lifecycle.reviewer.status,
        DispatchLifecycleStatus::WaitingForWorkerReview
    );
    assert_eq!(
        lifecycle.evaluator.status,
        DispatchLifecycleStatus::WaitingForReviewCompletion
    );
    assert_eq!(
        lifecycle.reviewer.required_consensus,
        Some(REVIEWER_CONSENSUS)
    );
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

#[test]
fn dispatch_policy_uses_supplied_board_root_pipeline() {
    let temp = tempdir().expect("tempdir");
    let board_root = temp.path().join("custom-board");
    let mut ws = PolicyCanvasWorkspace::seeded();
    let mut document = ws.active_canvas().unwrap().document.clone();
    document.edges.iter_mut().for_each(|edge| {
        if edge.id == "edge:default"
            && let PolicyGraphEdgeCondition::ActionIn { actions } = &mut edge.condition
        {
            actions.retain(|action| *action != PolicyAction::SpawnAgent);
        }
    });
    document.edges.push(PolicyGraphEdge {
        id: "edge:spawn-needs-human".to_string(),
        from_node: "action:router".to_string(),
        from_port: "default".to_string(),
        to_node: "human:unsafe-action".to_string(),
        to_port: "in".to_string(),
        label: None,
        condition: PolicyGraphEdgeCondition::ActionIn {
            actions: vec![PolicyAction::SpawnAgent],
        },
    });
    document.mode = PolicyGraphMode::Draft;
    assert!(
        document
            .nodes
            .iter()
            .any(|node| matches!(node.kind, PolicyGraphNodeKind::HumanGate { .. }))
    );
    let saved = apply_save_draft(&mut ws, document, 0, None).expect("save policy graph");
    apply_simulate(&mut ws, Some(saved.document.clone()), None).expect("simulate policy graph");
    let promoted = apply_promote(
        &mut ws,
        &PolicyPipelinePromoteRequest {
            revision: saved.document.revision,
            actor: None,
            canvas_id: None,
        },
    )
    .expect("promote policy graph");
    crate::task_board::policy_graph::store_gate_policy(&board_root, Some(promoted.document));

    let plan = build_dispatch_plan_with_policy_root(&ready_item(), &board_root);
    crate::task_board::policy_graph::store_gate_policy(&board_root, None);

    assert!(matches!(
        plan.readiness,
        DispatchReadiness::Blocked {
            reason: DispatchBlockReason::Policy { .. }
        }
    ));
}

#[test]
fn dispatch_policy_prefers_cached_gate_policy_over_disk() {
    let temp = tempdir().expect("tempdir");
    let board_root = temp.path().join("cached-board");
    // The seeded graph allows SpawnAgent; build a blocking enforced policy that
    // lives only in the gate cache, proving gating reads the cache, not disk.
    let mut document = PolicyGraph::seeded_v2();
    document.edges.iter_mut().for_each(|edge| {
        if edge.id == "edge:default"
            && let PolicyGraphEdgeCondition::ActionIn { actions } = &mut edge.condition
        {
            actions.retain(|action| *action != PolicyAction::SpawnAgent);
        }
    });
    document.edges.push(PolicyGraphEdge {
        id: "edge:spawn-needs-human".to_string(),
        from_node: "action:router".to_string(),
        from_port: "default".to_string(),
        to_node: "human:unsafe-action".to_string(),
        to_port: "in".to_string(),
        label: None,
        condition: PolicyGraphEdgeCondition::ActionIn {
            actions: vec![PolicyAction::SpawnAgent],
        },
    });
    document.mode = PolicyGraphMode::Enforced;
    crate::task_board::policy_graph::store_gate_policy(&board_root, Some(document));

    let plan = build_dispatch_plan_with_policy_root(&ready_item(), &board_root);
    crate::task_board::policy_graph::store_gate_policy(&board_root, None);

    assert!(matches!(
        plan.readiness,
        DispatchReadiness::Blocked {
            reason: DispatchBlockReason::Policy { .. }
        }
    ));
}
