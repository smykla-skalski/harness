use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::ExternalProvider;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
};

#[tokio::test]
async fn renewed_scope_lease_blocks_replacement_after_original_deadline() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let scope_id = "v1:github:write:12:acme/widgets";
    let attempt = start_attempt(&db, scope_id, "2026-07-16T10:00:00Z").await;

    db.renew_task_board_provider_scope_attempt(&attempt, "2026-07-16T10:14:59Z")
        .await
        .expect("renew attempt");
    let decision = db
        .begin_task_board_provider_scope_attempt(
            ExternalProvider::GitHub,
            scope_id,
            "2026-07-16T10:20:00Z",
        )
        .await
        .expect("begin contender");

    assert_eq!(decision, ExternalProviderScopeAttemptDecision::Fenced);
}

#[tokio::test]
async fn stale_scope_lease_cannot_renew_after_replacement() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let scope_id = "v1:github:write:12:acme/widgets";
    let stale = start_attempt(&db, scope_id, "2026-07-16T10:00:00Z").await;
    let current = start_attempt(&db, scope_id, "2026-07-16T10:16:00Z").await;

    let error = db
        .renew_task_board_provider_scope_attempt(&stale, "2026-07-16T10:16:01Z")
        .await
        .expect_err("stale attempt must not renew");

    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    db.renew_task_board_provider_scope_attempt(&current, "2026-07-16T10:16:01Z")
        .await
        .expect("current attempt renews");
}

async fn start_attempt(
    db: &AsyncDaemonDb,
    scope_id: &str,
    now: &str,
) -> ExternalProviderScopeAttempt {
    match db
        .begin_task_board_provider_scope_attempt(ExternalProvider::GitHub, scope_id, now)
        .await
        .expect("begin provider attempt")
    {
        ExternalProviderScopeAttemptDecision::Started(attempt) => attempt,
        other => panic!("expected started attempt, got {other:?}"),
    }
}
