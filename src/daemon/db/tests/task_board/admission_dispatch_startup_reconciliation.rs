use std::sync::{Arc, OnceLock};

use tokio::sync::broadcast;

use super::{
    admission_policy, configure_policy, create_plan, ledger_kind_state, preparing_intent, test_db,
};
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::{AsyncDaemonDb, complete_write_preparation};
use crate::daemon::protocol::{CodexRunStatus, StreamEvent};
use crate::task_board::AgentMode;

#[tokio::test]
async fn startup_reconciliation_releases_orphaned_codex_concurrency() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let plan = create_plan(&db, "admission-restart", AgentMode::Headless).await;
    let intent = preparing_intent(
        db.reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
            .await
            .expect("reserve dispatch"),
    );
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    complete_write_preparation(&db, &preparation, "branch", "/tmp/worktree")
        .await
        .expect("complete preparation");
    let claim = db
        .claim_task_board_dispatch("admission-restart")
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    let worker_id = format!("codex-{intent}");
    let run = super::super::super::sample_codex_run(&worker_id, "2026-07-17T10:00:00Z");
    db.save_codex_run(&run).await.expect("save active run");
    db.complete_task_board_dispatch(&intent, &claim.claim_token, &worker_id)
        .await
        .expect("commit worker admission");
    let before_recovery = db
        .current_change_sequence()
        .await
        .expect("load change sequence");

    let reopened = Arc::new(
        AsyncDaemonDb::connect(&db._directory.path().join("harness.db"))
            .await
            .expect("reopen async db"),
    );
    let (sender, _) = broadcast::channel::<StreamEvent>(8);
    let async_db_slot = Arc::new(OnceLock::new());
    async_db_slot
        .set(reopened.clone())
        .expect("install reopened async db");
    let controller = CodexControllerHandle::new_with_async_db(
        sender,
        Arc::new(OnceLock::new()),
        async_db_slot,
        false,
    );
    controller
        .reconcile_task_board_admission_workers_after_restart()
        .await
        .expect("reconcile orphaned worker admission");

    let reconciled = reopened
        .codex_run(&worker_id)
        .await
        .expect("load reconciled run")
        .expect("persisted run");
    assert_eq!(reconciled.status, CodexRunStatus::Failed);
    assert_eq!(
        ledger_kind_state(&reopened, &intent, "concurrency").await,
        "released"
    );
    assert_eq!(
        ledger_kind_state(&reopened, &intent, "rate").await,
        "committed"
    );
    assert!(
        reopened
            .current_change_sequence()
            .await
            .expect("load recovered change sequence")
            > before_recovery
    );
}
