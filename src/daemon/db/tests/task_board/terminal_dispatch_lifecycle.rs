use std::collections::HashMap;
use std::ops::Deref;

use tempfile::{TempDir, tempdir};

use crate::daemon::db::policy::consume_approval_grant_in_tx;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb, NewApprovalGrant, ReservedTaskBoardDispatch};
use crate::task_board::{
    AgentMode, PolicyAction, PolicyReasonCode, SpawnGateSwitches, TaskBoardAutomationPolicy,
    TaskBoardItem, TaskBoardPolicyLimit, TaskBoardPolicyScope, TaskBoardStatus,
    build_dispatch_plans_with_policy,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum IntentPhase {
    Held,
    Pending,
    Starting,
}

impl IntentPhase {
    const ALL: [Self; 3] = [Self::Held, Self::Pending, Self::Starting];

    const fn name(self) -> &'static str {
        match self {
            Self::Held => "held",
            Self::Pending => "pending",
            Self::Starting => "starting",
        }
    }

    const fn is_claimed(self) -> bool {
        matches!(self, Self::Starting)
    }
}

#[derive(Clone, Copy, Debug)]
enum TerminalAction {
    Complete,
    Delete,
}

impl TerminalAction {
    const fn name(self) -> &'static str {
        match self {
            Self::Complete => "complete",
            Self::Delete => "delete",
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
struct IntentSnapshot {
    status: String,
    claim_token: Option<String>,
    claimed_at: Option<String>,
    grant_id: Option<String>,
    last_error: Option<String>,
    completed_at: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
struct GrantSnapshot {
    state: String,
    consumed_at: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
struct LedgerSnapshot {
    state: String,
    expires_at: Option<String>,
    released_at: Option<String>,
}

struct Fixture {
    db: AsyncDaemonDb,
    _directory: TempDir,
    item_id: String,
    intent_id: String,
    grant_id: String,
    item_before: TaskBoardItem,
    intent_before: IntentSnapshot,
    grant_before: GrantSnapshot,
    ledger_before: Vec<LedgerSnapshot>,
}

#[tokio::test]
async fn terminal_transition_cancels_unclaimed_dispatches_and_fences_starting() {
    exercise_terminal_action(TerminalAction::Complete).await;
}

#[tokio::test]
async fn delete_cancels_unclaimed_dispatches_and_fences_starting() {
    exercise_terminal_action(TerminalAction::Delete).await;
}

async fn exercise_terminal_action(action: TerminalAction) {
    for phase in IntentPhase::ALL {
        let fixture = fixture(phase, action).await;
        let result = apply_action(&fixture.db, &fixture.item_id, action).await;
        if phase.is_claimed() {
            let error = result.expect_err("claimed starting dispatch must fence terminal mutation");
            assert!(
                error.to_string().contains("dispatch is claimed"),
                "unexpected {phase:?} {action:?} error: {error}"
            );
            assert_fenced_state(&fixture).await;
        } else {
            result.expect("unclaimed pre-start dispatch must cancel atomically");
            assert_cancelled_state(&fixture, action).await;
        }
    }
}

async fn apply_action(
    db: &AsyncDaemonDb,
    item_id: &str,
    action: TerminalAction,
) -> Result<(), crate::errors::CliError> {
    match action {
        TerminalAction::Complete => db
            .update_task_board_item(item_id, |item| {
                item.status = TaskBoardStatus::Done;
                Ok(true)
            })
            .await
            .map(|_| ()),
        TerminalAction::Delete => db.delete_task_board_item(item_id).await.map(|_| ()),
    }
}

async fn assert_cancelled_state(fixture: &Fixture, action: TerminalAction) {
    let item = fixture
        .db
        .task_board_item(&fixture.item_id)
        .await
        .expect("load cancelled item");
    match action {
        TerminalAction::Complete => assert_eq!(item.status, TaskBoardStatus::Done),
        TerminalAction::Delete => assert!(item.is_deleted()),
    }
    let intent = intent_snapshot(&fixture.db, &fixture.intent_id).await;
    assert_eq!(intent.status, "failed");
    assert!(intent.claim_token.is_none());
    assert!(intent.claimed_at.is_none());
    assert_eq!(intent.grant_id.as_deref(), Some(fixture.grant_id.as_str()));
    assert!(intent.completed_at.is_some());
    assert_eq!(
        grant_snapshot(&fixture.db, &fixture.grant_id).await,
        GrantSnapshot {
            state: "approved".to_string(),
            consumed_at: None,
        }
    );
    let ledger = ledger_snapshot(&fixture.db, &fixture.intent_id).await;
    assert!(!ledger.is_empty());
    assert!(ledger.iter().all(|row| {
        row.state == "released" && row.expires_at.is_none() && row.released_at.is_some()
    }));
}

async fn assert_fenced_state(fixture: &Fixture) {
    assert_eq!(
        fixture
            .db
            .task_board_item(&fixture.item_id)
            .await
            .expect("load fenced item"),
        fixture.item_before
    );
    assert_eq!(
        intent_snapshot(&fixture.db, &fixture.intent_id).await,
        fixture.intent_before
    );
    assert_eq!(
        grant_snapshot(&fixture.db, &fixture.grant_id).await,
        fixture.grant_before
    );
    assert_eq!(
        ledger_snapshot(&fixture.db, &fixture.intent_id).await,
        fixture.ledger_before
    );
}

async fn fixture(phase: IntentPhase, action: TerminalAction) -> Fixture {
    let TestDb { db, directory } = test_db().await;
    configure_policy(&db).await;
    let item_id = format!("terminal-{}-{}", phase.name(), action.name());
    let mut item = TaskBoardItem::new(
        item_id.clone(),
        "Terminal dispatch lifecycle".to_string(),
        "Body".to_string(),
        "2026-07-17T10:00:00Z".to_string(),
    );
    item.agent_mode = AgentMode::Headless;
    db.create_task_board_item(item).await.expect("create item");
    let grant_id = approved_grant(&db, &item_id).await;
    let mut plan = build_dispatch_plans_with_policy(
        &[db.task_board_item(&item_id).await.expect("load item")],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    plan.consumed_approval_grant_id = Some(grant_id.clone());
    let intent_id = preparing_intent(
        db.reserve_task_board_dispatch(
            &plan,
            "control-plane",
            Some("/tmp/project"),
            phase == IntentPhase::Held,
        )
        .await
        .expect("reserve dispatch"),
    );
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent_id)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    db.complete_task_board_dispatch_preparation(&preparation, "branch", "/tmp/worktree")
        .await
        .expect("publish dispatch");
    if phase == IntentPhase::Held {
        attach_consumed_grant_to_held_intent(&db, &intent_id, &grant_id).await;
    } else if phase == IntentPhase::Starting {
        db.claim_task_board_dispatch(&item_id)
            .await
            .expect("claim worker dispatch")
            .expect("pending worker dispatch");
    }
    let item_before = db
        .task_board_item(&item_id)
        .await
        .expect("load fixture item");
    let intent_before = intent_snapshot(&db, &intent_id).await;
    assert_eq!(intent_before.status, phase.name());
    let grant_before = grant_snapshot(&db, &grant_id).await;
    assert_eq!(grant_before.state, "approved");
    assert!(grant_before.consumed_at.is_some());
    let ledger_before = ledger_snapshot(&db, &intent_id).await;
    assert!(!ledger_before.is_empty());
    assert!(
        ledger_before.iter().any(|row| row.state == "reserved"),
        "fixture has no active admission reservation: {ledger_before:?}"
    );
    Fixture {
        db,
        _directory: directory,
        item_id,
        intent_id,
        grant_id,
        item_before,
        intent_before,
        grant_before,
        ledger_before,
    }
}

async fn approved_grant(db: &AsyncDaemonDb, item_id: &str) -> String {
    let grant = db
        .ensure_pending_approval_grant(&NewApprovalGrant {
            board_item_id: item_id.to_string(),
            action: PolicyAction::SpawnAgent,
            canvas_id: None,
            canvas_revision: 1,
            node_id: "approve-spawn".to_string(),
            reason_code: PolicyReasonCode::ApprovalRequired,
            expiry_seconds: None,
        })
        .await
        .expect("create approval grant");
    db.resolve_approval_grant(&grant.id, true, "operator")
        .await
        .expect("approve grant");
    grant.id
}

async fn attach_consumed_grant_to_held_intent(db: &AsyncDaemonDb, intent_id: &str, grant_id: &str) {
    let mut transaction = db.pool().begin().await.expect("begin grant transaction");
    assert!(
        consume_approval_grant_in_tx(&mut *transaction, grant_id)
            .await
            .expect("consume held grant")
    );
    sqlx::query(
        "UPDATE task_board_dispatch_intents SET consumed_approval_grant_id = ?2
         WHERE intent_id = ?1 AND status = 'held'",
    )
    .bind(intent_id)
    .bind(grant_id)
    .execute(&mut *transaction)
    .await
    .expect("attach held grant");
    transaction.commit().await.expect("commit held grant");
}

fn preparing_intent(outcome: ReservedTaskBoardDispatch) -> String {
    match outcome {
        ReservedTaskBoardDispatch::Preparing { intent_id, .. } => intent_id,
        ReservedTaskBoardDispatch::Applied(_) => panic!("new reservation already applied"),
        ReservedTaskBoardDispatch::Blocked(_) => panic!("admission blocked fixture"),
    }
}

async fn configure_policy(db: &AsyncDaemonDb) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    settings.admission_policy = TaskBoardAutomationPolicy {
        limits: vec![TaskBoardPolicyLimit::Concurrency {
            scope: TaskBoardPolicyScope::Global,
            limit: 10,
            reservation: 1,
        }],
        windows: Vec::new(),
    };
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("save settings");
}

struct TestDb {
    db: AsyncDaemonDb,
    directory: TempDir,
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
        directory,
    }
}

impl Deref for TestDb {
    type Target = AsyncDaemonDb;

    fn deref(&self) -> &Self::Target {
        &self.db
    }
}

async fn intent_snapshot(db: &AsyncDaemonDb, intent_id: &str) -> IntentSnapshot {
    let row = sqlx::query_as::<
        _,
        (
            String,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
        ),
    >(
        "SELECT status, claim_token, claimed_at, consumed_approval_grant_id,
                last_error, completed_at
         FROM task_board_dispatch_intents WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load intent snapshot");
    IntentSnapshot {
        status: row.0,
        claim_token: row.1,
        claimed_at: row.2,
        grant_id: row.3,
        last_error: row.4,
        completed_at: row.5,
    }
}

async fn grant_snapshot(db: &AsyncDaemonDb, grant_id: &str) -> GrantSnapshot {
    let (state, consumed_at) =
        sqlx::query_as("SELECT state, consumed_at FROM policy_approval_grants WHERE id = ?1")
            .bind(grant_id)
            .fetch_one(db.pool())
            .await
            .expect("load grant snapshot");
    GrantSnapshot { state, consumed_at }
}

async fn ledger_snapshot(db: &AsyncDaemonDb, intent_id: &str) -> Vec<LedgerSnapshot> {
    sqlx::query_as::<_, (String, Option<String>, Option<String>)>(
        "SELECT state, expires_at, released_at
         FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 ORDER BY canonical_key",
    )
    .bind(intent_id)
    .fetch_all(db.pool())
    .await
    .expect("load ledger snapshot")
    .into_iter()
    .map(|(state, expires_at, released_at)| LedgerSnapshot {
        state,
        expires_at,
        released_at,
    })
    .collect()
}
