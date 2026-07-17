use std::collections::HashMap;

use serde_json::json;
use tempfile::{TempDir, tempdir};

use super::*;
use crate::daemon::db::{NewApprovalGrant, ReservedTaskBoardDispatch};
use crate::task_board::policy_graph::PolicyCanvasWorkspace;
use crate::task_board::{
    PolicyApprovalGrant, PolicyGraph, PolicyReasonCode, TaskBoardItem, TaskBoardStatus,
    TaskBoardWorkflowStatus, build_dispatch_plans_with_policy,
};

struct HeldFixture {
    _dir: TempDir,
    db: AsyncDaemonDb,
    item_id: String,
    grant: PolicyApprovalGrant,
    graph: PolicyGraph,
}

async fn held_fixture() -> HeldFixture {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("connect");
    let item_id = "held-policy-item".to_string();
    let mut item = TaskBoardItem::new(
        item_id.clone(),
        "Held policy item".to_string(),
        "Body".to_string(),
        "2026-07-14T10:00:00Z".to_string(),
    );
    item.planning.summary = Some("Implement held policy validation".to_string());
    item.planning.approved_by = Some("operator".to_string());
    item.planning.approved_at = Some("2026-07-14T10:00:00Z".to_string());
    db.create_task_board_item(item).await.expect("create item");
    let graph = approval_graph(7);
    let mut workspace = PolicyCanvasWorkspace::seeded();
    let canvas = workspace.active_canvas_mut().expect("active canvas");
    canvas.mark_live(graph.clone());
    let canvas_id = canvas.id.clone();
    db.replace_policy_workspace(&workspace)
        .await
        .expect("store live workspace");
    let grant = db
        .ensure_pending_approval_grant(&NewApprovalGrant {
            board_item_id: item_id.clone(),
            action: PolicyAction::SpawnAgent,
            canvas_id: Some(canvas_id.clone()),
            canvas_revision: graph.revision,
            node_id: "approve-spawn".to_string(),
            reason_code: PolicyReasonCode::ApprovalRequired,
            expiry_seconds: Some(3600),
        })
        .await
        .expect("create grant");
    let grant = db
        .resolve_approval_grant(&grant.id, true, "operator")
        .await
        .expect("approve grant");
    let item = db.task_board_item(&item_id).await.expect("load item");
    let mut grants = HashMap::new();
    grants.insert(item_id.clone(), grant.clone());
    let plan = build_dispatch_plans_with_policy(
        &[item],
        Some((&canvas_id, &graph)),
        Some("2026-07-14T10:00:01Z"),
        SpawnGateSwitches {
            requires_live_policy: true,
            kill_switch: false,
        },
        &grants,
    )
    .remove(0);
    assert!(plan.is_ready(), "unexpected plan: {plan:?}");
    let reserved = db
        .reserve_task_board_dispatch(&plan, "operator", Some("/tmp/project"), true)
        .await
        .expect("reserve held dispatch");
    let intent_id = match reserved {
        ReservedTaskBoardDispatch::Preparing { intent_id, .. } => intent_id,
        ReservedTaskBoardDispatch::Applied(_) => panic!("fresh item already applied"),
        ReservedTaskBoardDispatch::Blocked(_) => panic!("default admission blocked reservation"),
    };
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent_id)
        .await
        .expect("claim preparation")
        .expect("preparation");
    db.complete_task_board_dispatch_preparation(
        &preparation,
        "harness/held-policy-item",
        "/tmp/held-policy-item",
    )
    .await
    .expect("publish held dispatch");
    assert!(
        db.live_approval_grant(&item_id, PolicyAction::SpawnAgent, graph.revision)
            .await
            .expect("live grant after hold")
            .is_some(),
        "holding must not consume approval"
    );
    HeldFixture {
        _dir: dir,
        db,
        item_id,
        grant,
        graph,
    }
}

#[tokio::test]
async fn held_delivery_rechecks_kill_switch_then_advances_worker_state() {
    let fixture = held_fixture().await;
    fixture
        .db
        .update_policy_workspace(|workspace| {
            workspace.spawn_kill_switch = true;
            Ok(())
        })
        .await
        .expect("enable kill switch");
    let error = fixture
        .db
        .claim_held_task_board_dispatch(&fixture.item_id)
        .await
        .expect_err("kill switch denies held delivery");
    assert!(error.message().contains("SpawnKillSwitchEngaged"));
    assert_eq!(
        fixture
            .db
            .held_task_board_dispatch_summary()
            .await
            .expect("held summary")
            .count,
        1
    );
    assert!(
        fixture
            .db
            .live_approval_grant(
                &fixture.item_id,
                PolicyAction::SpawnAgent,
                fixture.graph.revision,
            )
            .await
            .expect("grant after denial")
            .is_some()
    );
    fixture
        .db
        .update_policy_workspace(|workspace| {
            workspace.spawn_kill_switch = false;
            Ok(())
        })
        .await
        .expect("disable kill switch");

    let claim = fixture
        .db
        .claim_held_task_board_dispatch(&fixture.item_id)
        .await
        .expect("claim after kill switch clears");
    assert_eq!(
        claim.consumed_approval_grant_id.as_deref(),
        Some(fixture.grant.id.as_str())
    );
    assert_eq!(
        claim.applied.item.workflow.current_step_id.as_deref(),
        Some("dispatch")
    );
    let completed = fixture
        .db
        .complete_task_board_dispatch(&claim.intent_id, &claim.claim_token, "codex-held-test")
        .await
        .expect("complete start");
    assert_eq!(completed.workflow.status, TaskBoardWorkflowStatus::Running);
    assert_eq!(
        completed.workflow.current_step_id.as_deref(),
        Some("worker_running")
    );
}

#[tokio::test]
async fn failed_worker_start_restores_unexpired_one_shot_grant() {
    let fixture = held_fixture().await;
    let claim = fixture
        .db
        .claim_held_task_board_dispatch(&fixture.item_id)
        .await
        .expect("claim held delivery");
    fixture
        .db
        .fail_task_board_dispatch(
            &claim.intent_id,
            &claim.claim_token,
            claim.consumed_approval_grant_id.as_deref(),
            "worker did not start",
        )
        .await
        .expect("roll back start");
    assert!(
        fixture
            .db
            .live_approval_grant(
                &fixture.item_id,
                PolicyAction::SpawnAgent,
                fixture.graph.revision,
            )
            .await
            .expect("restored grant")
            .is_some(),
        "failed startup must restore the live approval"
    );
    let item = fixture
        .db
        .task_board_item(&fixture.item_id)
        .await
        .expect("rolled-back item");
    assert_eq!(item.status, TaskBoardStatus::Todo);
    assert_eq!(item.workflow.status, TaskBoardWorkflowStatus::Failed);
    assert_eq!(
        item.workflow.current_step_id.as_deref(),
        Some("worker_spawn")
    );
}

#[tokio::test]
async fn expired_or_revision_stale_grant_cannot_claim_held_delivery() {
    let fixture = held_fixture().await;
    sqlx::query(
        "UPDATE policy_approval_grants
         SET created_at = '2020-01-01T00:00:00Z', expiry_seconds = 1
         WHERE id = ?1",
    )
    .bind(&fixture.grant.id)
    .execute(fixture.db.pool())
    .await
    .expect("expire grant");
    let error = fixture
        .db
        .claim_held_task_board_dispatch(&fixture.item_id)
        .await
        .expect_err("expired approval denies delivery");
    assert!(error.message().contains("ApprovalRequired"));
    assert_eq!(
        fixture
            .db
            .held_task_board_dispatch_summary()
            .await
            .expect("held after expiry")
            .count,
        1
    );

    let fixture = held_fixture().await;
    fixture
        .db
        .update_policy_workspace(|workspace| {
            let mut changed = fixture.graph.clone();
            changed.revision += 1;
            workspace
                .active_canvas_mut()
                .expect("active canvas")
                .mark_live(changed);
            Ok(())
        })
        .await
        .expect("change live revision");
    let error = fixture
        .db
        .claim_held_task_board_dispatch(&fixture.item_id)
        .await
        .expect_err("revision-stale approval denies delivery");
    assert!(error.message().contains("ApprovalRequired"));
}

fn approval_graph(revision: u64) -> PolicyGraph {
    serde_json::from_value(json!({
        "schema_version": 2,
        "revision": revision,
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
                "kind": {
                    "kind": "approval_gate",
                    "reason_code": "approval_required",
                    "expiry_seconds": 3600
                },
                "input_ports": ["in"],
                "output_ports": ["approved"]
            },
            {
                "id": "finish-allow",
                "label": "Allow",
                "kind": {
                    "kind": "finish",
                    "decision": "allow",
                    "reason_code": "default_allow"
                },
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
    }))
    .expect("approval graph")
}
