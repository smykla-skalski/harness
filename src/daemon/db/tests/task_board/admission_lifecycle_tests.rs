use std::collections::HashMap;
use std::ops::Deref;

use chrono::{Duration, Timelike, Utc};
use tempfile::{TempDir, tempdir};

use crate::daemon::db::task_board::write_workflow_fixture::{
    approved_write_item, complete_write_preparation,
};
use crate::daemon::db::{AsyncDaemonDb, DaemonDb, ReservedTaskBoardDispatch};
use crate::task_board::{
    DispatchPlan, SpawnGateSwitches, TaskBoardAdmissionRequirement, TaskBoardAutomationPolicy,
    TaskBoardItem, TaskBoardLaunchCapability, TaskBoardOutsideWindowAction, TaskBoardPolicyLimit,
    TaskBoardPolicyScope, TaskBoardPolicyWeekday, TaskBoardPolicyWindow,
    build_dispatch_plans_with_policy, canonical_admission_requirement_key,
};

#[tokio::test]
async fn configured_policy_rejects_missing_decision_and_ledger_evidence() {
    let db = test_db().await;
    configure_policy(&db, concurrency_policy()).await;

    let renewal_intent = reserve(&db, "admission-missing-renewal", None).await;
    let renewal_claim = db
        .claim_task_board_dispatch_preparation(&renewal_intent)
        .await
        .expect("claim renewal preparation")
        .expect("pending renewal preparation");
    delete_admission_evidence(&db, &renewal_intent).await;
    let renewal_error = db
        .renew_task_board_dispatch_preparation(&renewal_claim)
        .await
        .expect_err("configured renewal without evidence must fail");
    assert!(
        renewal_error
            .to_string()
            .contains("without a current allowed decision under the configured policy")
    );

    let commit_intent = reserve(&db, "admission-missing-commit", None).await;
    let preparation = db
        .claim_task_board_dispatch_preparation(&commit_intent)
        .await
        .expect("claim commit preparation")
        .expect("pending commit preparation");
    complete_write_preparation(&db, &preparation, "branch", "/tmp/worktree")
        .await
        .expect("complete commit preparation");
    let dispatch = db
        .claim_task_board_dispatch("admission-missing-commit")
        .await
        .expect("claim commit dispatch")
        .expect("pending commit dispatch");
    delete_admission_evidence(&db, &commit_intent).await;
    let commit_error = db
        .complete_task_board_dispatch(
            &commit_intent,
            &dispatch.claim_token,
            "codex-missing-admission",
        )
        .await
        .expect_err("configured commit without evidence must fail");
    assert!(
        commit_error
            .to_string()
            .contains("without a current allowed decision under the configured policy")
    );
}

#[tokio::test]
async fn empty_policy_preserves_evidenceless_renewal_and_commit() {
    let db = test_db().await;
    configure_policy(&db, TaskBoardAutomationPolicy::default()).await;
    let intent = reserve(&db, "admission-empty-policy", None).await;
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim empty-policy preparation")
        .expect("pending empty-policy preparation");

    db.renew_task_board_dispatch_preparation(&preparation)
        .await
        .expect("renew empty-policy preparation");
    complete_write_preparation(&db, &preparation, "branch", "/tmp/worktree")
        .await
        .expect("complete empty-policy preparation");
    let dispatch = db
        .claim_task_board_dispatch("admission-empty-policy")
        .await
        .expect("claim empty-policy dispatch")
        .expect("pending empty-policy dispatch");
    db.renew_task_board_dispatch_claim(&intent, &dispatch.claim_token)
        .await
        .expect("renew empty-policy worker claim");
    db.complete_task_board_dispatch(&intent, &dispatch.claim_token, "codex-empty-policy")
        .await
        .expect("commit empty-policy dispatch");
}

#[tokio::test]
async fn renewal_recompiles_a_closed_time_window_reservation() {
    let db = test_db().await;
    configure_policy(&db, active_time_window_policy()).await;
    let intent = reserve(&db, "admission-window-rollover", None).await;
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim window preparation")
        .expect("pending window preparation");
    let initial_generation = current_generation(&db, &intent).await;
    let stale_end = make_time_window_stale(&db, &intent).await;

    db.renew_task_board_dispatch_preparation(&preparation)
        .await
        .expect("recompile closed time window");

    assert!(current_generation(&db, &intent).await > initial_generation);
    let (start, end) = current_window(&db, &intent, "time_window").await;
    let now = Utc::now();
    assert!(start <= now && now < end);
    assert_ne!(end, stale_end);
}

#[tokio::test]
async fn claim_heartbeat_and_commit_keep_the_frozen_start_authorization() {
    let db = test_db().await;
    configure_policy(&db, active_time_window_policy()).await;
    let intent = reserve(&db, "admission-authorized-window", None).await;
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim authorized preparation")
        .expect("pending authorized preparation");
    complete_write_preparation(&db, &preparation, "branch", "/tmp/worktree")
        .await
        .expect("complete authorized preparation");
    let dispatch = db
        .claim_task_board_dispatch("admission-authorized-window")
        .await
        .expect("claim authorized dispatch")
        .expect("pending authorized dispatch");
    db.validate_task_board_dispatch_admission_start(
        &intent,
        &dispatch.claim_token,
        Some(TaskBoardLaunchCapability::WorkspaceWrite),
        None,
    )
    .await
    .expect("authorize worker start");
    let authorized_generation = current_generation(&db, &intent).await;
    let authorized_window_end = make_time_window_stale(&db, &intent).await;

    db.renew_task_board_dispatch_claim(&intent, &dispatch.claim_token)
        .await
        .expect("renew frozen worker claim");

    assert_eq!(
        current_generation(&db, &intent).await,
        authorized_generation
    );
    assert_eq!(
        current_window(&db, &intent, "time_window").await.1,
        authorized_window_end
    );

    db.complete_task_board_dispatch(&intent, &dispatch.claim_token, "codex-authorized-window")
        .await
        .expect("commit frozen authorized reservation");

    assert_eq!(
        current_generation(&db, &intent).await,
        authorized_generation
    );
    assert_eq!(current_ledger_state(&db, &intent).await, "committed");
}

#[tokio::test]
async fn worker_claim_renewal_rejects_orphaned_admission_ledger() {
    let db = test_db().await;
    configure_policy(&db, concurrency_policy()).await;
    let intent = reserve(&db, "admission-orphaned-ledger", None).await;
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim orphan preparation")
        .expect("pending orphan preparation");
    complete_write_preparation(&db, &preparation, "branch", "/tmp/worktree")
        .await
        .expect("complete orphan preparation");
    let dispatch = db
        .claim_task_board_dispatch("admission-orphaned-ledger")
        .await
        .expect("claim orphan dispatch")
        .expect("pending orphan dispatch");
    sqlx::query(
        "UPDATE task_board_dispatch_admission_decisions
         SET is_current = 0, superseded_at = created_at
         WHERE intent_id = ?1 AND is_current = 1",
    )
    .bind(&intent)
    .execute(db.pool())
    .await
    .expect("orphan reserved ledger evidence");

    let error = db
        .renew_task_board_dispatch_claim(&intent, &dispatch.claim_token)
        .await
        .expect_err("orphaned worker admission evidence must fail closed");
    assert!(
        error
            .to_string()
            .contains("reserved ledger rows without a current allowed decision")
    );
}

#[tokio::test]
async fn renewal_recompiles_rate_token_and_cost_bucket_rollover() {
    let db = test_db().await;
    configure_policy(&db, windowed_budget_policy()).await;
    let intent = reserve(&db, "admission-budget-rollover", Some((40, 75_000))).await;
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim budget preparation")
        .expect("pending budget preparation");
    let initial_generation = current_generation(&db, &intent).await;
    shift_current_buckets_back(&db, &intent).await;

    db.renew_task_board_dispatch_preparation(&preparation)
        .await
        .expect("recompile stale budget buckets");

    assert!(current_generation(&db, &intent).await > initial_generation);
    for kind in ["rate", "token_budget", "monetary_budget"] {
        let (start, end) = current_window(&db, &intent, kind).await;
        let now = Utc::now();
        assert!(start <= now && now < end, "stale {kind} bucket survived");
    }
}

struct TestDb {
    db: AsyncDaemonDb,
    _directory: TempDir,
}

impl Deref for TestDb {
    type Target = AsyncDaemonDb;

    fn deref(&self) -> &Self::Target {
        &self.db
    }
}

async fn test_db() -> TestDb {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let sync_db = DaemonDb::open(&path).expect("open sync db");
    let project = super::super::sample_project();
    sync_db.sync_project(&project).expect("sync project");
    let session = super::super::sample_session_state();
    sync_db
        .sync_session(&project.project_id, &session)
        .expect("sync session");
    drop(sync_db);
    TestDb {
        db: AsyncDaemonDb::connect(&path).await.expect("open db"),
        _directory: directory,
    }
}

async fn configure_policy(db: &AsyncDaemonDb, policy: TaskBoardAutomationPolicy) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    settings.admission_policy = policy;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("save settings");
}

async fn reserve(db: &AsyncDaemonDb, item_id: &str, estimates: Option<(u64, u64)>) -> String {
    let mut item = approved_write_item(TaskBoardItem::new(
        item_id.to_string(),
        "Admission lifecycle".to_string(),
        "Body".to_string(),
        "2026-07-17T10:00:00Z".to_string(),
    ));
    if let Some((tokens, cost)) = estimates {
        item.estimated_tokens = Some(tokens);
        item.estimated_cost_microusd = Some(cost);
    }
    db.create_task_board_item(item).await.expect("create item");
    let plan = dispatch_plan(db, item_id).await;
    match db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("reserve dispatch")
    {
        ReservedTaskBoardDispatch::Preparing { intent_id, .. } => intent_id,
        ReservedTaskBoardDispatch::Applied(_) => panic!("new reservation already applied"),
        ReservedTaskBoardDispatch::Blocked(value) => {
            panic!(
                "reservation unexpectedly blocked: {}",
                value.refusal_message()
            )
        }
    }
}

async fn dispatch_plan(db: &AsyncDaemonDb, item_id: &str) -> DispatchPlan {
    let item = db.task_board_item(item_id).await.expect("load item");
    build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0)
}

fn concurrency_policy() -> TaskBoardAutomationPolicy {
    TaskBoardAutomationPolicy {
        limits: vec![TaskBoardPolicyLimit::Concurrency {
            scope: TaskBoardPolicyScope::Global,
            limit: 1,
            reservation: 1,
        }],
        windows: Vec::new(),
    }
}

fn active_time_window_policy() -> TaskBoardAutomationPolicy {
    let now = Utc::now();
    let start = now - Duration::minutes(2);
    let end = now + Duration::minutes(2);
    TaskBoardAutomationPolicy {
        limits: Vec::new(),
        windows: vec![TaskBoardPolicyWindow {
            scope: TaskBoardPolicyScope::Global,
            timezone: "UTC".to_string(),
            weekdays: all_weekdays(),
            start_time: format!("{:02}:{:02}", start.hour(), start.minute()),
            end_time: format!("{:02}:{:02}", end.hour(), end.minute()),
            outside_action: TaskBoardOutsideWindowAction::Deny,
        }],
    }
}

fn all_weekdays() -> Vec<TaskBoardPolicyWeekday> {
    use TaskBoardPolicyWeekday::{Friday, Monday, Saturday, Sunday, Thursday, Tuesday, Wednesday};
    vec![
        Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday,
    ]
}

fn windowed_budget_policy() -> TaskBoardAutomationPolicy {
    TaskBoardAutomationPolicy {
        limits: vec![
            TaskBoardPolicyLimit::Rate {
                scope: TaskBoardPolicyScope::Global,
                limit: 10,
                window_seconds: 60,
                reservation: 1,
            },
            TaskBoardPolicyLimit::TokenBudget {
                scope: TaskBoardPolicyScope::Global,
                limit: 1_000,
                window_seconds: 60,
            },
            TaskBoardPolicyLimit::MonetaryBudget {
                scope: TaskBoardPolicyScope::Global,
                limit_microusd: 1_000_000,
                window_seconds: 60,
            },
        ],
        windows: Vec::new(),
    }
}

async fn delete_admission_evidence(db: &AsyncDaemonDb, intent_id: &str) {
    sqlx::query("DELETE FROM task_board_dispatch_admission_ledger WHERE intent_id = ?1")
        .bind(intent_id)
        .execute(db.pool())
        .await
        .expect("delete ledger evidence");
    sqlx::query("DELETE FROM task_board_dispatch_admission_decisions WHERE intent_id = ?1")
        .bind(intent_id)
        .execute(db.pool())
        .await
        .expect("delete decision evidence");
}

async fn current_generation(db: &AsyncDaemonDb, intent_id: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT generation FROM task_board_dispatch_admission_decisions
         WHERE intent_id = ?1 AND is_current = 1",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load current generation")
}

async fn current_ledger_state(db: &AsyncDaemonDb, intent_id: &str) -> String {
    sqlx::query_scalar(
        "SELECT state FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND state != 'released'",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load current ledger state")
}

async fn make_time_window_stale(db: &AsyncDaemonDb, intent_id: &str) -> chrono::DateTime<Utc> {
    let (decision_id, requirements_json): (String, String) = sqlx::query_as(
        "SELECT decision_id, requirements_json
         FROM task_board_dispatch_admission_decisions
         WHERE intent_id = ?1 AND is_current = 1",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load time-window decision");
    let mut requirements: Vec<TaskBoardAdmissionRequirement> =
        serde_json::from_str(&requirements_json).expect("decode requirements");
    let requirement = requirements.first_mut().expect("time-window requirement");
    let start = chrono::DateTime::parse_from_rfc3339(
        requirement.available_at.as_deref().expect("window start"),
    )
    .expect("parse window start")
    .with_timezone(&Utc)
        - Duration::days(1);
    requirement.available_at = Some(start.to_rfc3339_opts(chrono::SecondsFormat::Secs, true));
    let end = start
        + Duration::seconds(
            i64::try_from(requirement.window_seconds.expect("window duration"))
                .expect("persisted duration"),
        );
    let key = canonical_admission_requirement_key(requirement)
        .expect("canonical stale requirement")
        .stable_id();
    sqlx::query(
        "UPDATE task_board_dispatch_admission_decisions SET requirements_json = ?2
         WHERE decision_id = ?1",
    )
    .bind(&decision_id)
    .bind(serde_json::to_string(&requirements).expect("encode stale requirements"))
    .execute(db.pool())
    .await
    .expect("update stale decision");
    sqlx::query(
        "UPDATE task_board_dispatch_admission_ledger
         SET canonical_key = ?2, window_started_at = ?3, window_ends_at = ?4
         WHERE decision_id = ?1",
    )
    .bind(&decision_id)
    .bind(key)
    .bind(start.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
    .bind(end.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
    .execute(db.pool())
    .await
    .expect("update stale ledger window");
    end
}

async fn shift_current_buckets_back(db: &AsyncDaemonDb, intent_id: &str) {
    sqlx::query(
        "UPDATE task_board_dispatch_admission_ledger
         SET window_started_at = strftime('%Y-%m-%dT%H:%M:%SZ', window_started_at, '-60 seconds'),
             window_ends_at = strftime('%Y-%m-%dT%H:%M:%SZ', window_ends_at, '-60 seconds')
         WHERE intent_id = ?1 AND kind IN ('rate', 'token_budget', 'monetary_budget')
           AND state = 'reserved'",
    )
    .bind(intent_id)
    .execute(db.pool())
    .await
    .expect("shift admission buckets");
}

async fn current_window(
    db: &AsyncDaemonDb,
    intent_id: &str,
    kind: &str,
) -> (chrono::DateTime<Utc>, chrono::DateTime<Utc>) {
    let (start, end): (String, String) = sqlx::query_as(
        "SELECT window_started_at, window_ends_at
         FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND kind = ?2 AND state = 'reserved'",
    )
    .bind(intent_id)
    .bind(kind)
    .fetch_one(db.pool())
    .await
    .expect("load current admission window");
    (
        chrono::DateTime::parse_from_rfc3339(&start)
            .expect("parse current window start")
            .with_timezone(&Utc),
        chrono::DateTime::parse_from_rfc3339(&end)
            .expect("parse current window end")
            .with_timezone(&Utc),
    )
}
