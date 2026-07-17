use std::time::Duration;

use tokio::time::timeout;

use crate::daemon::agent_tui::AgentTuiStatus;
use crate::daemon::protocol::{CodexRunStatus, ManagedAgentSnapshot};
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::SessionRole;
use crate::task_board::AgentMode;

use super::test_support::{applied_task, codex_snapshot, terminal_snapshot, test_http_state};
use super::{
    begin_worker_compensation, codex_worker_id, codex_worker_request, exact_worker_not_found,
    managed_worker_id, recover_same_session_worker, resolve_start_failure,
    start_worker_for_applied_task, stop_worker_in_lane, terminal_worker_id,
    terminal_worker_request,
};

#[test]
fn codex_worker_request_carries_task_board_identity() {
    let applied = applied_task(AgentMode::Headless);

    let request = codex_worker_request(&applied, "codex-dispatch-intent-1");

    assert_eq!(request.task_id.as_deref(), Some("task-1"));
    assert_eq!(request.board_item_id.as_deref(), Some("board-1"));
    assert_eq!(request.workflow_execution_id.as_deref(), Some("workflow-1"));
    assert_eq!(request.role, SessionRole::Leader);
    assert_eq!(request.fallback_role, Some(SessionRole::Worker));
    assert!(
        request
            .capabilities
            .contains(&"task-board:item:board-1".to_string())
    );
    assert!(request.prompt.contains("Session task: task-1"));
    assert!(request.prompt.contains("Session id:\nsession-1"));
    assert!(request.prompt.contains("Tags:\nbackend"));
    assert!(request.prompt.contains("Worktree:\n/tmp/task-worktree"));
    assert!(request.prompt.contains("External refs:\ngithub:123"));
    assert!(
        request
            .prompt
            .contains("Managed run id:\ncodex-dispatch-intent-1")
    );
    assert!(
        request
            .prompt
            .contains("harness session task list session-1 --json")
    );
    assert!(
        request
            .prompt
            .contains("harness session task submit-for-review session-1 task-1")
    );
    assert!(request.prompt.contains("authoritative safety net"));
}

#[test]
fn planning_and_evaluate_workers_are_report_only() {
    for mode in [AgentMode::Planning, AgentMode::Evaluate] {
        let applied = applied_task(mode);
        let request = codex_worker_request(&applied, "codex-read-only");

        assert_eq!(request.mode, crate::daemon::protocol::CodexRunMode::Report);
    }
}

#[test]
fn interactive_worker_request_uses_terminal_runtime() {
    let applied = applied_task(AgentMode::Interactive);

    let request = terminal_worker_request(&applied, "agent-tui-dispatch-intent-1");

    assert_eq!(request.runtime, "codex");
    assert_eq!(request.task_id.as_deref(), Some("task-1"));
    assert_eq!(request.board_item_id.as_deref(), Some("board-1"));
    assert_eq!(request.role, SessionRole::Leader);
    assert_eq!(request.fallback_role, Some(SessionRole::Worker));
    assert_eq!(request.rows, 24);
    assert_eq!(request.cols, 80);
}

#[test]
fn worker_identity_is_stable_for_reclaimed_dispatch_claims() {
    assert_eq!(
        codex_worker_id("dispatch-intent-1"),
        codex_worker_id("dispatch-intent-1")
    );
    assert_eq!(
        terminal_worker_id("dispatch-intent-1"),
        terminal_worker_id("dispatch-intent-1")
    );
    assert_ne!(
        codex_worker_id("dispatch-intent-1"),
        codex_worker_id("dispatch-intent-2")
    );
}

#[test]
fn terminal_and_failed_same_session_workers_are_recovered() {
    let snapshots = [
        ManagedAgentSnapshot::Terminal(terminal_snapshot(AgentTuiStatus::Stopped, "session-1")),
        ManagedAgentSnapshot::Codex(codex_snapshot(CodexRunStatus::Failed, "session-1")),
    ];

    for snapshot in snapshots {
        let expected_id = snapshot.agent_id().to_string();
        let recovered = resolve_start_failure(start_failure(), Ok(Some(snapshot)), "session-1")
            .expect("same-session durable worker evidence");
        assert_eq!(recovered.agent_id(), expected_id);
    }
}

#[test]
fn deterministic_worker_from_another_session_fails_closed() {
    let snapshot =
        ManagedAgentSnapshot::Codex(codex_snapshot(CodexRunStatus::Running, "different-session"));

    let error = recover_same_session_worker(snapshot, "session-1")
        .expect_err("cross-session deterministic identity must conflict");

    assert_eq!(error.code(), "KSRCLI092");
}

#[test]
fn only_exact_deterministic_lookup_miss_allows_start() {
    let worker_id = codex_worker_id("dispatch-intent-1");
    let exact: CliError =
        CliErrorKind::session_not_active(format!("codex run '{worker_id}' not found")).into();
    let uncertain: CliError =
        CliErrorKind::session_not_active("codex controller not active").into();

    assert!(exact_worker_not_found(
        &exact,
        AgentMode::Headless,
        &worker_id
    ));
    assert!(!exact_worker_not_found(
        &uncertain,
        AgentMode::Headless,
        &worker_id
    ));
}

#[test]
fn uncertain_probe_errors_are_not_rollback_safe() {
    let probe_error = CliErrorKind::workflow_io("managed worker lookup failed").into();
    let error = resolve_start_failure(start_failure(), Err(probe_error), "session-1")
        .expect_err("uncertain second probe must retain recovery ownership");

    assert!(!error.may_rollback());
    assert_eq!(error.into_cli_error().code(), "WORKFLOW_IO");
}

#[test]
fn exact_post_start_miss_is_rollback_safe() {
    let error = resolve_start_failure(start_failure(), Ok(None), "session-1")
        .expect_err("exact second miss preserves the start failure");

    assert!(error.may_rollback());
    assert_eq!(error.into_cli_error().code(), "WORKFLOW_IO");
}

fn start_failure() -> CliError {
    CliErrorKind::workflow_io("managed worker start failed before persistence").into()
}

#[tokio::test]
async fn worker_start_waits_for_lane_before_preflight() {
    let state = test_http_state();
    let applied = applied_task(AgentMode::Interactive);
    let intent_id = "dispatch-intent-test";
    let outer_guard = state
        .managed_agent_mutation_locks
        .lock(&applied.session_id, &managed_worker_id(&applied, intent_id))
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
    let error = timeout(Duration::from_secs(2), future)
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
    seed_session(&db, &applied.session_id).await;
    let mut snapshot = codex_snapshot(CodexRunStatus::Running, &applied.session_id);
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

async fn seed_session(db: &crate::daemon::db::AsyncDaemonDb, session_id: &str) {
    let now = "2026-07-17T10:00:00Z";
    let state_json = serde_json::json!({
        "schema_version": crate::session::types::CURRENT_VERSION,
        "session_id": session_id,
        "context": "managed-agent recovery",
        "status": "active",
        "created_at": now,
        "updated_at": now,
    })
    .to_string();
    sqlx::query(
        "INSERT INTO projects (
             project_id, name, checkout_id, checkout_name, context_root,
             is_worktree, discovered_at, updated_at
         ) VALUES ('project-1', 'harness', 'checkout-1', 'main',
                   '/tmp/harness-managed-agent-test', 0, ?1, ?1)",
    )
    .bind(now)
    .execute(db.pool())
    .await
    .expect("seed managed-agent project");
    sqlx::query(
        "INSERT INTO sessions (
             session_id, project_id, schema_version, context, status,
             created_at, updated_at, state_json
         ) VALUES (?1, 'project-1', 3, 'managed-agent recovery', 'active',
                   ?2, ?2, ?3)",
    )
    .bind(session_id)
    .bind(now)
    .bind(state_json)
    .execute(db.pool())
    .await
    .expect("seed managed-agent session");
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
        .lock(&applied.session_id, &worker_id)
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
    let error = timeout(Duration::from_secs(2), future)
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
