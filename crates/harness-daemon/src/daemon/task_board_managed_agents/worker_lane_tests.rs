use std::time::Duration;

use tokio::time::timeout;

use crate::daemon::protocol::CodexRunStatus;
use crate::daemon::test_liveness::LIVENESS;
use crate::task_board::AgentMode;

use super::test_support::{applied_task, codex_snapshot, seed_owner_session, test_http_state};
use super::{
    begin_worker_compensation, managed_worker_id, start_worker_for_applied_task,
    stop_worker_in_lane, worker_lock_owner,
};
use crate::daemon::db::prelude::*;

#[tokio::test]
async fn worker_start_waits_for_lane_before_preflight() {
    let state = test_http_state();
    let applied = applied_task(AgentMode::Interactive);
    let intent_id = "dispatch-intent-test";
    let outer_guard = state
        .managed_agent_mutation_locks
        .lock(
            &worker_lock_owner(&applied),
            &managed_worker_id(&applied, intent_id),
        )
        .await;
    let future = start_worker_for_applied_task(&state, &applied, intent_id, "stale-claim");
    tokio::pin!(future);

    assert!(
        timeout(Duration::from_millis(50), future.as_mut())
            .await
            .is_err(),
        "worker probe and preflight must wait for the deterministic worker lane",
    );

    drop(outer_guard);
    let error = timeout(LIVENESS, future)
        .await
        .expect("worker start resumes once the lane is free")
        .expect_err("test has no dispatch claim");
    assert!(error.may_rollback());
}

#[tokio::test]
async fn deterministic_worker_evidence_precedes_claim_preflight() {
    let state = test_http_state();
    let db = state.async_db.get().cloned().expect("test async db");
    let applied = applied_task(AgentMode::Headless);
    let intent_id = "dispatch-intent-reclaimed";
    let worker_id = managed_worker_id(&applied, intent_id);
    seed_owner_session(&db, &applied).await;
    let mut snapshot = codex_snapshot(
        CodexRunStatus::Running,
        applied
            .launch_owner_id()
            .expect("a dispatched task has an owner"),
    );
    snapshot.run_id.clone_from(&worker_id);
    snapshot.board_item_id = Some(applied.board_item_id.clone());
    snapshot.task_id = Some(applied.work_item_id.clone());
    snapshot.workflow_execution_id = applied.item.workflow.execution_id.clone();
    snapshot.session_agent_id = None;
    db.save_codex_run(&snapshot)
        .await
        .expect("persist deterministic worker evidence");

    let recovered = start_worker_for_applied_task(&state, &applied, intent_id, "stale-claim")
        .await
        .expect("existing worker must be recovered before claim validation");

    assert_eq!(recovered.agent_id(), worker_id);
}

#[tokio::test]
async fn compensation_renews_claim_inside_worker_lane_before_stop() {
    let state = test_http_state();
    let db = state.async_db.get().cloned().expect("test async db");
    let applied = applied_task(AgentMode::Interactive);
    let intent_id = "dispatch-intent-compensation";
    let worker_id = managed_worker_id(&applied, intent_id);
    let outer_guard = state
        .managed_agent_mutation_locks
        .lock(&worker_lock_owner(&applied), &worker_id)
        .await;
    let future = begin_worker_compensation(
        &state,
        &db,
        &applied,
        intent_id,
        "stale-claim",
        "completion failed",
    );
    tokio::pin!(future);

    assert!(
        timeout(Duration::from_millis(50), future.as_mut())
            .await
            .is_err(),
        "compensation must wait for the deterministic worker lane",
    );

    drop(outer_guard);
    let error = timeout(LIVENESS, future)
        .await
        .expect("compensation resumes once the lane is free")
        .expect_err("stale owner must fail before stop");
    assert!(error.to_string().contains("lost its claim"));
    assert!(!error.to_string().contains("terminal agent"));
}

#[tokio::test]
async fn compensation_resume_accepts_a_worker_already_stopped_before_crash() {
    let state = test_http_state();
    let applied = applied_task(AgentMode::Interactive);
    let worker_id = managed_worker_id(&applied, "dispatch-intent-crash-resume");

    stop_worker_in_lane(&state, &applied, worker_id)
        .await
        .expect("missing deterministic worker proves the prior stop already completed");
}
