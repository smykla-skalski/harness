use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;
use chrono::DateTime;
use sqlx::{query, query_as};
use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
    ExternalProviderScopeHealth, ExternalProviderScopeIdentity,
};
use crate::task_board::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConflictPolicy, ExternalSyncDirection,
    ExternalSyncOptions, ExternalTask, ExternalTaskRef, TaskBoardItem,
};

#[tokio::test]
async fn concurrent_scope_claims_admit_exactly_one_attempt() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let first_db = db.clone();
    let second_db = db.clone();

    let (first, second) = tokio::join!(
        first_db.begin_task_board_provider_scope_attempt(
            ExternalProvider::GitHub,
            "v1:github:read:12:acme/widgets",
            "2026-07-16T10:00:00Z",
        ),
        second_db.begin_task_board_provider_scope_attempt(
            ExternalProvider::GitHub,
            "v1:github:read:12:acme/widgets",
            "2026-07-16T10:00:00Z",
        ),
    );
    let decisions = [first.expect("first claim"), second.expect("second claim")];

    assert_eq!(
        decisions
            .iter()
            .filter(|decision| matches!(decision, ExternalProviderScopeAttemptDecision::Started(_)))
            .count(),
        1
    );
    assert_eq!(
        decisions
            .iter()
            .filter(|decision| matches!(decision, ExternalProviderScopeAttemptDecision::Fenced))
            .count(),
        1
    );
}

#[tokio::test]
async fn active_attempt_fences_batch_without_duplicate_provider_call() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let calls = Arc::new(AtomicUsize::new(0));
    let client = CountingPullClient::successful(Arc::clone(&calls));
    let scope_id = ExternalProviderScopeIdentity::for_client(&client)
        .scope_id()
        .to_owned();
    let now = crate::workspace::utc_now();
    let _attempt = start_attempt(&db, &scope_id, &now).await;
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    let batch =
        crate::task_board::external::sync_external_tasks_scoped(&db, sync_options(false), &clients)
            .await
            .expect("fenced batch");

    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert_eq!(batch.attempted_scope_count(), 0);
    assert_eq!(batch.backing_off_scope_count(), 1);
}

#[tokio::test]
async fn stale_attempt_results_cannot_replace_newer_scope_state() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let success_scope = "v1:github:write:12:acme/widgets";
    let failure_scope = "v1:github:read:12:acme/widgets";

    let stale_success = start_attempt(&db, success_scope, "2026-07-16T10:00:00Z").await;
    let current_failure = start_attempt(&db, success_scope, "2026-07-16T10:16:00Z").await;
    let stale_error = db
        .complete_task_board_provider_scope_success(
            &stale_success,
            Some("stale-revision"),
            "2026-07-16T10:17:00Z",
        )
        .await
        .expect_err("stale success must not clear a newer attempt");
    assert_eq!(stale_error.code(), "WORKFLOW_CONCURRENT");
    db.complete_task_board_provider_scope_failure(&current_failure, "2026-07-16T10:17:00Z")
        .await
        .expect("current failure");
    let failed = db
        .task_board_provider_scope_state(ExternalProvider::GitHub, success_scope)
        .await
        .expect("failed state");
    assert_eq!(failed.failure_count, 1);
    assert_eq!(failed.base_revision, None);

    let stale_failure = start_attempt(&db, failure_scope, "2026-07-16T11:00:00Z").await;
    let current_success = start_attempt(&db, failure_scope, "2026-07-16T11:16:00Z").await;
    let stale_error = db
        .complete_task_board_provider_scope_failure(&stale_failure, "2026-07-16T11:17:00Z")
        .await
        .expect_err("stale failure must not overwrite a newer attempt");
    assert_eq!(stale_error.code(), "WORKFLOW_CONCURRENT");
    db.complete_task_board_provider_scope_success(
        &current_success,
        Some("current-revision"),
        "2026-07-16T11:17:00Z",
    )
    .await
    .expect("current success");
    let succeeded = db
        .task_board_provider_scope_state(ExternalProvider::GitHub, failure_scope)
        .await
        .expect("successful state");
    assert_eq!(succeeded.failure_count, 0);
    assert_eq!(succeeded.base_revision.as_deref(), Some("current-revision"));
}

#[tokio::test]
async fn persisted_exponential_backoff_caps_at_ten_minutes() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let scope_id = "v1:github:read:12:acme/widgets";
    let expected_delays = [30_i64, 120, 480, 600, 600, 600];

    for (index, expected_delay) in expected_delays.into_iter().enumerate() {
        let attempt = start_attempt(&db, scope_id, "2026-07-16T12:00:00Z").await;
        db.complete_task_board_provider_scope_failure(&attempt, "2026-07-16T12:00:00Z")
            .await
            .expect("record failure");
        let (updated_at, backoff_until) = query_as::<_, (String, String)>(
            "SELECT updated_at, backoff_until
             FROM task_board_provider_scope_state
             WHERE provider = 'github' AND scope_id = ?1",
        )
        .bind(scope_id)
        .fetch_one(db.pool())
        .await
        .expect("read backoff");
        let delay = DateTime::parse_from_rfc3339(&backoff_until).expect("deadline")
            - DateTime::parse_from_rfc3339(&updated_at).expect("updated at");

        assert_eq!(delay.num_seconds(), expected_delay);
        assert_eq!(
            db.task_board_provider_scope_state(ExternalProvider::GitHub, scope_id)
                .await
                .expect("scope state")
                .failure_count,
            u32::try_from(index + 1).expect("failure count")
        );
        query(
            "UPDATE task_board_provider_scope_state
             SET backoff_until = '2000-01-01T00:00:00Z'
             WHERE provider = 'github' AND scope_id = ?1",
        )
        .bind(scope_id)
        .execute(db.pool())
        .await
        .expect("expire backoff");
    }
}

#[tokio::test]
async fn dry_run_success_and_failure_leave_provider_state_unchanged() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let calls = Arc::new(AtomicUsize::new(0));
    let successful = CountingPullClient::successful(Arc::clone(&calls));
    let scope_id = ExternalProviderScopeIdentity::for_client(&successful)
        .scope_id()
        .to_owned();
    let attempt = start_attempt(&db, &scope_id, "2026-07-16T12:00:00Z").await;
    db.complete_task_board_provider_scope_failure(&attempt, "2026-07-16T12:00:00Z")
        .await
        .expect("seed failure");
    query(
        "UPDATE task_board_provider_scope_state
         SET backoff_until = '2000-01-01T00:00:00Z'
         WHERE provider = 'github' AND scope_id = ?1",
    )
    .bind(&scope_id)
    .execute(db.pool())
    .await
    .expect("expire backoff");
    let before = provider_state_row(&db, &scope_id).await;

    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(successful)];
    crate::task_board::external::sync_external_tasks_scoped(&db, sync_options(true), &clients)
        .await
        .expect("successful dry run");
    assert_eq!(provider_state_row(&db, &scope_id).await, before);

    let clients: Vec<Box<dyn ExternalSyncClient>> =
        vec![Box::new(CountingPullClient::failing(Arc::clone(&calls)))];
    let batch =
        crate::task_board::external::sync_external_tasks_scoped(&db, sync_options(true), &clients)
            .await
            .expect("failed provider dry run still returns batch");
    assert_eq!(batch.failed_scope_count(), 1);
    assert_eq!(provider_state_row(&db, &scope_id).await, before);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn neutral_release_preserves_failure_count_without_backoff() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let scope_id = "v1:todoist:write:7:scope-a";
    let initial = start_attempt_for(
        &db,
        ExternalProvider::Todoist,
        scope_id,
        "2026-07-16T13:00:00Z",
    )
    .await;
    db.complete_task_board_provider_scope_failure(&initial, "2026-07-16T13:00:00Z")
        .await
        .expect("seed failure");
    query(
        "UPDATE task_board_provider_scope_state
         SET backoff_until = '2000-01-01T00:00:00Z'
         WHERE provider = 'todoist' AND scope_id = ?1",
    )
    .bind(scope_id)
    .execute(db.pool())
    .await
    .expect("expire backoff");
    let current = start_attempt_for(
        &db,
        ExternalProvider::Todoist,
        scope_id,
        "2026-07-16T13:10:01Z",
    )
    .await;
    let revision_before = db
        .task_board_revision()
        .await
        .expect("revision before release");

    db.release_task_board_provider_scope_attempt(&current, "2026-07-16T13:10:02Z")
        .await
        .expect("release attempt");

    let state = db
        .task_board_provider_scope_state(ExternalProvider::Todoist, scope_id)
        .await
        .expect("scope state");
    assert_eq!(state.health, ExternalProviderScopeHealth::Healthy);
    assert_eq!(state.failure_count, 1);
    assert_eq!(state.backoff_until, None);
    assert!(
        db.task_board_revision()
            .await
            .expect("revision after release")
            > revision_before
    );
}

#[tokio::test]
async fn neutral_release_removes_a_new_attempt_row() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let scope_id = "v1:todoist:write:7:scope-b";
    let attempt = start_attempt_for(
        &db,
        ExternalProvider::Todoist,
        scope_id,
        "2026-07-16T14:00:00Z",
    )
    .await;

    db.release_task_board_provider_scope_attempt(&attempt, "2026-07-16T14:00:01Z")
        .await
        .expect("release attempt");

    let rows = query_as::<_, (i64,)>(
        "SELECT COUNT(*) FROM task_board_provider_scope_state
         WHERE provider = 'todoist' AND scope_id = ?1",
    )
    .bind(scope_id)
    .fetch_one(db.pool())
    .await
    .expect("count scope rows");
    assert_eq!(rows.0, 0);
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

async fn start_attempt_for(
    db: &AsyncDaemonDb,
    provider: ExternalProvider,
    scope_id: &str,
    now: &str,
) -> ExternalProviderScopeAttempt {
    match db
        .begin_task_board_provider_scope_attempt(provider, scope_id, now)
        .await
        .expect("begin provider attempt")
    {
        ExternalProviderScopeAttemptDecision::Started(attempt) => attempt,
        other => panic!("expected started attempt, got {other:?}"),
    }
}

async fn provider_state_row(
    db: &AsyncDaemonDb,
    scope_id: &str,
) -> (Option<String>, String, i64, Option<String>, String) {
    query_as(
        "SELECT base_revision, health, failure_count, backoff_until, updated_at
         FROM task_board_provider_scope_state
         WHERE provider = 'github' AND scope_id = ?1",
    )
    .bind(scope_id)
    .fetch_one(db.pool())
    .await
    .expect("provider state row")
}

fn sync_options(dry_run: bool) -> ExternalSyncOptions {
    ExternalSyncOptions {
        status: None,
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Pull,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run,
    }
}

struct CountingPullClient {
    calls: Arc<AtomicUsize>,
    fails: bool,
}

impl CountingPullClient {
    fn successful(calls: Arc<AtomicUsize>) -> Self {
        Self {
            calls,
            fails: false,
        }
    }

    fn failing(calls: Arc<AtomicUsize>) -> Self {
        Self { calls, fails: true }
    }
}

#[async_trait]
impl ExternalSyncClient for CountingPullClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn scope_id(&self) -> String {
        "acme/widgets".into()
    }

    fn allows_push(&self) -> bool {
        false
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if self.fails {
            return Err(CliErrorKind::workflow_io("provider unavailable").into());
        }
        Ok(Vec::new())
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("pull-only test client")
    }
}
