use crate::agents::turn::{AgentTurnId, AgentTurnRequest, AgentTurnRuntime, AgentTurnStatus};
use crate::daemon::codex_controller::CodexAgentTurnRuntime;
use crate::daemon::protocol::{CodexRunMode, CodexRunStatus};

use super::test_support::{
    codex_run_snapshot, controller_with_db, with_isolated_async_harness_env,
};

const SESSION_ID: &str = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";

#[tokio::test]
async fn shared_lifecycle_starts_a_codex_report_run() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, _db, _tempdir) = controller_with_db();
        let runtime = CodexAgentTurnRuntime::new(controller.clone(), SESSION_ID);
        let lifecycle: &dyn AgentTurnRuntime = &runtime;

        let id = lifecycle
            .start(AgentTurnRequest {
                prompt: "Prepare the report".into(),
                requested_model: Some("gpt-5.5".into()),
            })
            .await
            .expect("start Codex turn");

        assert_eq!(lifecycle.runtime(), "codex");
        assert_eq!(
            lifecycle.status(&id).await.expect("queued status"),
            AgentTurnStatus::Queued
        );
        let snapshot = controller.run(id.as_str()).expect("load Codex run");
        assert_eq!(snapshot.mode, CodexRunMode::Report);
        assert_eq!(snapshot.prompt, "Prepare the report");
        assert_eq!(snapshot.model.as_deref(), Some("gpt-5.5"));
    })
    .await;
}

#[tokio::test]
async fn completed_codex_turn_returns_one_stable_report() {
    let (controller, db, _tempdir) = controller_with_db();
    let mut snapshot = report_snapshot(CodexRunStatus::Completed);
    snapshot.final_message = Some("Complete Codex report".into());
    db.lock()
        .expect("db lock")
        .save_codex_run(&snapshot)
        .expect("save completed run");
    let runtime = CodexAgentTurnRuntime::new(controller, SESSION_ID);
    let id = AgentTurnId::new(snapshot.run_id).expect("turn id");

    let result = runtime
        .result(&id)
        .await
        .expect("load result")
        .expect("completed result");
    assert_eq!(result.correlation_id, id);
    assert_eq!(result.report, "Complete Codex report");
    assert_eq!(result.stop_reason, "end_turn");
    assert_eq!(
        runtime.result(&id).await.expect("reload result"),
        Some(result)
    );
    assert_eq!(
        runtime.cancel(&id).await.expect("cancel completed turn"),
        AgentTurnStatus::Completed
    );
}

#[tokio::test]
async fn codex_cancellation_uses_the_shared_terminal_state() {
    let (controller, db, _tempdir) = controller_with_db();
    let snapshot = report_snapshot(CodexRunStatus::Running);
    db.lock()
        .expect("db lock")
        .save_codex_run(&snapshot)
        .expect("save running run");
    let runtime = CodexAgentTurnRuntime::new(controller, SESSION_ID);
    let id = AgentTurnId::new(snapshot.run_id).expect("turn id");

    assert_eq!(
        runtime.cancel(&id).await.expect("cancel running turn"),
        AgentTurnStatus::Cancelled
    );
    assert_eq!(
        runtime.cancel(&id).await.expect("cancel again"),
        AgentTurnStatus::Cancelled
    );
    assert!(runtime.result(&id).await.expect("load result").is_none());
}

#[tokio::test]
async fn codex_turn_ids_remain_scoped_to_the_bound_session() {
    let (controller, db, _tempdir) = controller_with_db();
    let mut snapshot = report_snapshot(CodexRunStatus::Running);
    snapshot.session_id = "another-session".into();
    db.lock()
        .expect("db lock")
        .save_codex_run(&snapshot)
        .expect("save other session run");
    let runtime = CodexAgentTurnRuntime::new(controller.clone(), SESSION_ID);
    let id = AgentTurnId::new(snapshot.run_id).expect("turn id");

    let error = runtime
        .cancel(&id)
        .await
        .expect_err("other session turn must be rejected");
    assert_eq!(error.code(), "SESSION_SCOPE_DENIED");
    assert!(error.to_string().contains("does not belong"));
    assert_eq!(
        controller
            .load_run(id.as_str())
            .expect("load untouched run")
            .status,
        CodexRunStatus::Running
    );
}

#[tokio::test]
async fn non_report_codex_runs_are_rejected_by_the_shared_lifecycle() {
    let (controller, db, _tempdir) = controller_with_db();
    let snapshot = codex_run_snapshot(CodexRunStatus::Running);
    db.lock()
        .expect("db lock")
        .save_codex_run(&snapshot)
        .expect("save workspace-write run");
    let runtime = CodexAgentTurnRuntime::new(controller.clone(), SESSION_ID);
    let id = AgentTurnId::new(snapshot.run_id).expect("turn id");

    let error = runtime
        .cancel(&id)
        .await
        .expect_err("workspace-write run must be rejected");
    assert!(error.to_string().contains("is not a report run"));
    assert_eq!(
        controller
            .load_run(id.as_str())
            .expect("load untouched run")
            .status,
        CodexRunStatus::Running
    );
}

fn report_snapshot(status: CodexRunStatus) -> crate::daemon::protocol::CodexRunSnapshot {
    let mut snapshot = codex_run_snapshot(status);
    snapshot.mode = CodexRunMode::Report;
    snapshot.pending_approvals.clear();
    snapshot
}
