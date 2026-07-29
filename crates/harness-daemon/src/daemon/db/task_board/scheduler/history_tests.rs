use chrono::Duration;
use serde_json::json;
use sqlx::{query, query_as, query_scalar};

use super::test_support::{acquire_request, database, instant, seed_run};
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardAutomationRunAdmission, TaskBoardAutomationRunLease,
};
use crate::task_board::{
    TaskBoardAutomationHistoryRequest, TaskBoardAutomationRunOutcome, TaskBoardAutomationRunStage,
    TaskBoardAutomationRunTrigger,
};

#[tokio::test]
async fn history_limit_and_tie_cursor_are_stable() {
    let db = database().await;
    let completed_at = instant("2026-07-15T10:00:00Z");
    for index in 0..501 {
        seed_run(
            &db,
            &format!("run-{index:03}"),
            "terminal",
            Some("completed"),
            Some(completed_at),
        )
        .await;
    }

    let bounded = history(&db, Some(900), None).await;
    assert_eq!(bounded.runs.len(), 500);
    assert_eq!(bounded.runs[0].run_id, "run-500");
    assert_eq!(bounded.runs[499].run_id, "run-001");
    assert!(bounded.has_older);
    assert_eq!(
        bounded.next_cursor.as_deref(),
        Some("2026-07-15T10:00:00+00:00|run-001")
    );

    let final_page = history(&db, Some(2), bounded.next_cursor).await;
    assert_eq!(run_ids(&final_page.runs), ["run-000"]);
    assert!(!final_page.has_older);
    assert_eq!(final_page.next_cursor, None);

    let minimum = history(&db, Some(0), None).await;
    assert_eq!(minimum.runs.len(), 1);
    assert_eq!(minimum.runs[0].run_id, "run-500");
    assert!(
        db.task_board_automation_history(&TaskBoardAutomationHistoryRequest {
            limit: Some(2),
            before: Some("invalid".into()),
        })
        .await
        .is_err()
    );
}

#[tokio::test]
async fn detail_reads_fenced_public_stages_canonically() {
    let db = database().await;
    let now = instant("2026-07-15T12:00:00Z");
    let lease = acquire_run(&db, "run-detail", now).await;
    db.upsert_task_board_automation_run_stage(&lease, &stage(2, "evaluate"), now)
        .await
        .expect("write second stage");
    db.upsert_task_board_automation_run_stage(&lease, &stage(1, "synchronize"), now)
        .await
        .expect("write first stage");
    db.finalize_task_board_automation_run(
        &lease,
        TaskBoardAutomationRunOutcome::Failed,
        Some("stage_failed"),
        Some("neutral failure"),
        now,
    )
    .await
    .expect("finalize run");

    let detail = db
        .task_board_automation_run_detail(&lease.run_id)
        .await
        .expect("load run detail")
        .expect("detail exists");
    assert_eq!(stage_sequences(&detail.stages), [1, 2]);
    assert_eq!(detail.error_kind.as_deref(), Some("stage_failed"));
    assert_eq!(detail.error.as_deref(), Some("neutral failure"));
}

#[tokio::test]
async fn lightweight_reads_skip_detail_payloads() {
    let db = database().await;
    let completed_at = instant("2026-07-15T12:30:00Z");
    seed_run(
        &db,
        "run-lightweight-history",
        "terminal",
        Some("completed"),
        Some(completed_at),
    )
    .await;
    seed_run(&db, "run-lightweight-active", "running", None, None).await;
    query(
        "UPDATE task_board_orchestrator_runs
         SET stage_summary_json = X'80', error_kind = X'80', error = X'80'",
    )
    .execute(db.pool())
    .await
    .expect("seed non-text detail payloads");

    assert_eq!(
        run_ids(&history(&db, Some(1), None).await.runs),
        ["run-lightweight-history"]
    );
    assert_eq!(
        db.active_task_board_automation_run()
            .await
            .expect("load active run")
            .expect("active run exists")
            .run_id,
        "run-lightweight-active"
    );
    let mut connection = db.pool().acquire().await.expect("acquire snapshot reader");
    let snapshot_runs = super::history::load_snapshot_run_infos(&mut connection)
        .await
        .expect("load snapshot runs");
    let mut snapshot_run_ids = run_ids(&snapshot_runs);
    snapshot_run_ids.sort_unstable();
    assert_eq!(
        snapshot_run_ids,
        ["run-lightweight-active", "run-lightweight-history"]
    );
    assert!(
        db.task_board_automation_run_detail("run-lightweight-history")
            .await
            .is_err()
    );
}

#[tokio::test]
async fn detail_rejects_noncanonical_persisted_stages() {
    let db = database().await;
    seed_run(
        &db,
        "run-malformed-detail",
        "terminal",
        Some("completed"),
        Some(instant("2026-07-15T13:00:00Z")),
    )
    .await;
    for stored in [
        r#"{"stages":[{"sequence":1,"stage":"sync","state":"completed","recorded_at":"2026-07-15T13:00:00Z","extra":true}]}"#,
        r#"{"stages":[{"sequence":1,"stage":"sync","state":"completed","recorded_at":"2026-07-15T13:00:00Z"},{"sequence":1,"stage":"sync","state":"failed","recorded_at":"2026-07-15T13:01:00Z"}]}"#,
        r#"{"stages":[{"sequence":1,"sequence":2,"stage":"sync","state":"completed","recorded_at":"2026-07-15T13:00:00Z"}]}"#,
        r#"{"stages":[],"stages":[]}"#,
    ] {
        query(
            "UPDATE task_board_orchestrator_runs SET stage_summary_json = ?1
             WHERE run_id = 'run-malformed-detail'",
        )
        .bind(stored)
        .execute(db.pool())
        .await
        .expect("seed malformed stages");
        assert!(
            db.task_board_automation_run_detail("run-malformed-detail")
                .await
                .is_err()
        );
    }
}

#[tokio::test]
async fn successful_finalization_owns_bounded_terminal_retention() {
    let db = database().await;
    let first_at = instant("2026-07-15T12:00:00Z");
    let second_at = first_at + Duration::minutes(1);
    let strict_boundary = second_at - Duration::days(30);
    for index in 0..102 {
        seed_run(
            &db,
            &format!("old-{index:03}"),
            "terminal",
            Some("completed"),
            Some(strict_boundary - Duration::days(1) - Duration::seconds(index)),
        )
        .await;
    }
    seed_run(
        &db,
        "boundary",
        "terminal",
        Some("completed"),
        Some(strict_boundary),
    )
    .await;
    seed_run(
        &db,
        "newer",
        "terminal",
        Some("completed"),
        Some(strict_boundary + Duration::seconds(1)),
    )
    .await;

    finalize_new_run(&db, "retention-owner-one", first_at).await;
    assert_eq!(old_run_count(&db).await, 2);
    assert!(run_exists(&db, "boundary").await);
    assert!(run_exists(&db, "newer").await);
    assert!(run_exists(&db, "retention-owner-one").await);

    finalize_new_run(&db, "retention-owner-two", second_at).await;
    assert_eq!(old_run_count(&db).await, 0);
    assert!(run_exists(&db, "boundary").await);
    assert!(run_exists(&db, "retention-owner-two").await);
}

async fn history(
    db: &AsyncDaemonDb,
    limit: Option<u32>,
    before: Option<String>,
) -> crate::task_board::TaskBoardAutomationHistoryResponse {
    db.task_board_automation_history(&TaskBoardAutomationHistoryRequest { limit, before })
        .await
        .expect("load history")
}

fn run_ids(runs: &[crate::task_board::TaskBoardAutomationRunInfo]) -> Vec<&str> {
    runs.iter().map(|run| run.run_id.as_str()).collect()
}

fn stage(sequence: u64, name: &str) -> TaskBoardAutomationRunStage {
    TaskBoardAutomationRunStage {
        sequence,
        stage: name.into(),
        state: "completed".into(),
        recorded_at: "2026-07-15T12:00:00Z".into(),
        summary: None,
        payload: Some(json!({ "neutral": true })),
    }
}

fn stage_sequences(stages: &[TaskBoardAutomationRunStage]) -> Vec<u64> {
    stages.iter().map(|stage| stage.sequence).collect()
}

async fn acquire_run(
    db: &AsyncDaemonDb,
    run_id: &str,
    now: chrono::DateTime<chrono::Utc>,
) -> TaskBoardAutomationRunLease {
    match db
        .try_acquire_task_board_automation_run(&acquire_request(
            run_id,
            TaskBoardAutomationRunTrigger::Manual,
            now,
        ))
        .await
        .expect("acquire run")
    {
        TaskBoardAutomationRunAdmission::Acquired(lease) => lease,
        admission => panic!("expected acquired run, got {admission:?}"),
    }
}

async fn finalize_new_run(db: &AsyncDaemonDb, run_id: &str, now: chrono::DateTime<chrono::Utc>) {
    let lease = acquire_run(db, run_id, now).await;
    db.finalize_task_board_automation_run(
        &lease,
        TaskBoardAutomationRunOutcome::Completed,
        None,
        None,
        now,
    )
    .await
    .expect("finalize retention owner");
}

async fn old_run_count(db: &AsyncDaemonDb) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_orchestrator_runs WHERE run_id LIKE 'old-%'")
        .fetch_one(db.pool())
        .await
        .expect("count old runs")
}

async fn run_exists(db: &AsyncDaemonDb, run_id: &str) -> bool {
    query_as::<_, (i64,)>(
        "SELECT EXISTS(SELECT 1 FROM task_board_orchestrator_runs WHERE run_id = ?1)",
    )
    .bind(run_id)
    .fetch_one(db.pool())
    .await
    .expect("check retained run")
    .0 == 1
}
