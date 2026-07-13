use super::*;
use crate::task_board::planning::{approve_plan, submit_plan};
use crate::task_board::policy::{
    PolicyAction, PolicyApprovalGrant, PolicyApprovalState, PolicyReasonCode,
};
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

fn spawn_decision(
    policy: Option<(&str, &PolicyGraph)>,
    switches: SpawnGateSwitches,
) -> PolicyDecision {
    let item = ready_item();
    let plans = build_dispatch_plans_with_policy(&[item], policy, None, switches, &HashMap::new());
    plans.into_iter().next().expect("one plan").policy
}

fn enforced_allow_graph() -> PolicyGraph {
    PolicyGraph::seeded_v2().with_mode(PolicyGraphMode::Enforced)
}

#[test]
fn graph_decision_threads_recorded_decision_id_into_the_plan() {
    let graph = enforced_allow_graph();
    let item = ready_item();
    let plans = build_dispatch_plans_with_policy(
        &[item],
        Some(("canvas-1", &graph)),
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    );
    let plan = plans.into_iter().next().expect("one plan");
    let decision_id = plan
        .policy_decision_id
        .expect("graph decision records an id");
    assert!(
        decision_id.starts_with("policy-decision-"),
        "threaded id must be the recorded decision id, got {decision_id}"
    );
}

#[test]
fn builtin_fallback_decision_has_no_recorded_id() {
    let item = ready_item();
    let plans = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    );
    let plan = plans.into_iter().next().expect("one plan");
    assert!(
        plan.policy_decision_id.is_none(),
        "the built-in fallback gate records no decision, so no id is threaded"
    );
}

#[test]
fn kill_switch_denies_spawn_even_with_an_allowing_graph() {
    let graph = enforced_allow_graph();
    let decision = spawn_decision(
        Some(("canvas-1", &graph)),
        SpawnGateSwitches {
            kill_switch: true,
            requires_live_policy: false,
        },
    );
    assert!(matches!(
        decision,
        PolicyDecision::Deny {
            reason_code: PolicyReasonCode::SpawnKillSwitchEngaged,
            ..
        }
    ));
}

#[test]
fn fail_closed_denies_spawn_when_no_live_policy_exists() {
    let decision = spawn_decision(
        None,
        SpawnGateSwitches {
            kill_switch: false,
            requires_live_policy: true,
        },
    );
    assert!(matches!(
        decision,
        PolicyDecision::Deny {
            reason_code: PolicyReasonCode::SpawnPolicyRequired,
            ..
        }
    ));
}

#[test]
fn fail_open_allows_spawn_when_no_live_policy_and_switch_off() {
    let decision = spawn_decision(None, SpawnGateSwitches::default());
    assert!(decision.is_allow());
}

#[test]
fn fail_closed_defers_to_live_graph_when_present() {
    let graph = enforced_allow_graph();
    let decision = spawn_decision(
        Some(("canvas-1", &graph)),
        SpawnGateSwitches {
            kill_switch: false,
            requires_live_policy: true,
        },
    );
    assert!(decision.is_allow());
}

#[test]
fn spawn_policy_input_fills_subject_enrichment_and_evaluated_at() {
    let mut item = ready_item();
    item.priority = TaskBoardPriority::Critical;
    item.agent_mode = AgentMode::Interactive;
    item.project_id = Some("project-1".into());
    item.tags = vec!["cli".into(), "board".into()];
    item.target_project_types = vec!["kuma".into(), "kuma-mesh".into()];

    let input = super::spawn_policy_input(&item, Some("2026-07-13T12:00:00Z".into()));

    assert_eq!(input.action, PolicyAction::SpawnAgent);
    assert_eq!(input.subject.task_board_item_id.as_deref(), Some("task-1"));
    assert_eq!(input.subject.repository.as_deref(), Some("project-1"));
    assert_eq!(input.subject.tags, ["cli", "board"]);
    assert_eq!(input.subject.priority, Some(TaskBoardPriority::Critical));
    assert_eq!(input.subject.agent_mode, Some(AgentMode::Interactive));
    assert_eq!(input.subject.target_project_types, ["kuma", "kuma-mesh"]);
    assert_eq!(input.evaluated_at.as_deref(), Some("2026-07-13T12:00:00Z"));
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
    assert!(
        plan.rendered_prompt
            .contains("Session task: <assigned-at-dispatch>")
    );
    assert!(plan.rendered_prompt.contains("Tags:\ncli, board"));
    assert!(plan.rendered_prompt.contains("External refs:\ngithub:123"));
    assert_eq!(
        serde_json::to_value(&plan).expect("serialize plan")["rendered_prompt"],
        plan.rendered_prompt
    );
}

#[test]
fn dispatch_plan_decodes_legacy_payload_without_rendered_prompt() {
    let plan = build_dispatch_plan(&ready_item());
    let mut value = serde_json::to_value(&plan).expect("serialize plan");
    value
        .as_object_mut()
        .expect("plan object")
        .remove("rendered_prompt");

    let decoded: DispatchPlan =
        serde_json::from_value(value).expect("decode legacy plan without rendered_prompt");

    assert_eq!(decoded.rendered_prompt, String::new());
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
        id: "edge:spawn-needs-human".into(),
        from_node: "action:router".into(),
        from_port: "default".into(),
        to_node: "human:unsafe-action".into(),
        to_port: "in".into(),
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
        id: "edge:spawn-needs-human".into(),
        from_node: "action:router".into(),
        from_port: "default".into(),
        to_node: "human:unsafe-action".into(),
        to_port: "in".into(),
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

/// `ActionGate[spawn_agent] -> ApprovalGate -> Finish(allow)`: the manual spawn
/// approval policy the dispatch lifecycle drives grants through.
fn approval_spawn_graph() -> PolicyGraph {
    let graph = serde_json::json!({
        "schema_version": 2,
        "revision": 1,
        "mode": "enforced",
        "nodes": [
            {
                "id": "gate-spawn",
                "label": "Spawn gate",
                "kind": { "kind": "action_gate", "actions": ["spawn_agent"] },
                "input_ports": ["in"],
                "output_ports": ["match", "default"]
            },
            {
                "id": "approve-spawn",
                "label": "Approve spawn",
                "kind": { "kind": "approval_gate", "reason_code": "approval_required" },
                "input_ports": ["in"],
                "output_ports": ["approved"]
            },
            {
                "id": "finish-allow",
                "label": "Allow",
                "kind": { "kind": "finish", "decision": "allow", "reason_code": "default_allow" },
                "input_ports": ["in"],
                "output_ports": []
            }
        ],
        "edges": [
            {
                "id": "edge-gate-to-approval",
                "from_node": "gate-spawn",
                "from_port": "match",
                "to_node": "approve-spawn",
                "to_port": "in",
                "condition": { "condition": "action_in", "actions": ["spawn_agent"] }
            },
            {
                "id": "edge-approval-to-finish",
                "from_node": "approve-spawn",
                "from_port": "approved",
                "to_node": "finish-allow",
                "to_port": "in",
                "condition": { "condition": "always" }
            }
        ],
        "groups": [],
        "layout": {}
    });
    serde_json::from_value(graph).expect("approval spawn graph deserializes")
}

fn test_grant(state: PolicyApprovalState) -> PolicyApprovalGrant {
    PolicyApprovalGrant {
        id: "policy-grant-test".to_owned(),
        board_item_id: "task-1".to_owned(),
        action: PolicyAction::SpawnAgent,
        canvas_id: Some("canvas-1".to_owned()),
        canvas_revision: 1,
        node_id: "approve-spawn".to_owned(),
        reason_code: PolicyReasonCode::ApprovalRequired,
        state,
        resolved_by: None,
        resolved_at: None,
        consumed_at: None,
        expiry_seconds: None,
        created_at: "2026-07-14T00:00:00Z".to_owned(),
        updated_at: "2026-07-14T00:00:00Z".to_owned(),
    }
}

fn dispatch_with_grant(grant: Option<PolicyApprovalGrant>) -> DispatchPlan {
    let graph = approval_spawn_graph();
    let mut grants = HashMap::new();
    if let Some(grant) = grant {
        grants.insert("task-1".to_owned(), grant);
    }
    build_dispatch_plans_with_policy(
        &[ready_item()],
        Some(("canvas-1", &graph)),
        None,
        SpawnGateSwitches::default(),
        &grants,
    )
    .into_iter()
    .next()
    .expect("one plan")
}

#[test]
fn approved_grant_allows_spawn_and_marks_the_grant_for_consumption() {
    let plan = dispatch_with_grant(Some(test_grant(PolicyApprovalState::Approved)));
    assert!(plan.policy.is_allow());
    assert_eq!(
        plan.consumed_approval_grant_id.as_deref(),
        Some("policy-grant-test"),
        "an approved grant that clears its gate is marked for one-shot consumption"
    );
}

#[test]
fn pending_grant_blocks_spawn_and_consumes_nothing() {
    let plan = dispatch_with_grant(Some(test_grant(PolicyApprovalState::Pending)));
    assert!(matches!(plan.policy, PolicyDecision::RequireHuman { .. }));
    assert!(plan.consumed_approval_grant_id.is_none());
}

#[test]
fn missing_grant_blocks_spawn_and_consumes_nothing() {
    let plan = dispatch_with_grant(None);
    assert!(matches!(plan.policy, PolicyDecision::RequireHuman { .. }));
    assert!(plan.consumed_approval_grant_id.is_none());
}

#[test]
fn denied_grant_denies_spawn_and_consumes_nothing() {
    let plan = dispatch_with_grant(Some(test_grant(PolicyApprovalState::Denied)));
    assert!(matches!(plan.policy, PolicyDecision::Deny { .. }));
    assert!(plan.consumed_approval_grant_id.is_none());
}
