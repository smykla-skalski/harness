use chrono::{Duration, SecondsFormat, Utc};
use sqlx::query_scalar;

use super::{TaskBoardRemoteControllerReport, canonical_now, offer_remote_candidates};
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteControllerScanStep, TaskBoardRemoteOfferOutcome,
    remote_controller_fixture,
};
use crate::errors::CliErrorKind;
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_REMOTE_PROTOCOL_VERSION,
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionHostAdvertisement,
    TaskBoardPhaseCapabilityProfile, TaskBoardWorkflowExecutionCas,
};

#[path = "task_board_remote_controller_tests/active_poll.rs"]
mod active_poll;
#[path = "task_board_remote_controller_tests/foreground_gate.rs"]
mod foreground_gate;
#[path = "task_board_remote_controller_tests/terminal.rs"]
mod terminal;
#[path = "task_board_remote_controller_tests/unknown.rs"]
mod unknown;

#[tokio::test]
async fn eligible_initial_attempt_selects_remote_before_any_local_run() {
    let fixture = remote_controller_fixture(1).await;
    refresh_fixture_observation(&fixture, 1, 0).await;
    let mut report = TaskBoardRemoteControllerReport::default();

    offer_remote_candidates(&fixture.db, &mut report)
        .await
        .expect("select eligible remote target");

    assert_eq!(report.offered_attempts, 1);
    let durable = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load remote-selected execution")
        .expect("remote-selected execution exists");
    assert_eq!(durable.attempts[0].state, TaskBoardAttemptState::Starting);
    assert!(
        durable
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .is_some_and(|target| target.starts_with("remote:"))
    );
    assert_eq!(assignment_count(&fixture).await, 1);
    assert_eq!(codex_run_count(&fixture).await, 0);
}

#[tokio::test]
async fn no_eligible_host_selects_one_local_target_before_claim() {
    let fixture = remote_controller_fixture(1).await;
    // A valid host advertises at least one slot; a fully-occupied host is the "no eligible host" case.
    refresh_fixture_observation(&fixture, 1, 1).await;
    let mut report = TaskBoardRemoteControllerReport::default();

    offer_remote_candidates(&fixture.db, &mut report)
        .await
        .expect("select local target after no eligible host");

    assert_eq!(report.offered_attempts, 0);
    let selected = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load local-selected execution")
        .expect("local-selected execution exists");
    let selected_attempt = selected.attempts[0].clone();
    assert_eq!(selected_attempt.state, TaskBoardAttemptState::Starting);
    assert_eq!(
        selected
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .map(String::as_str),
        Some("local")
    );
    assert_eq!(assignment_count(&fixture).await, 0);

    let mut running = selected_attempt.clone();
    running.state = TaskBoardAttemptState::Running;
    running.updated_at = canonical_now();
    assert!(
        fixture
            .db
            .claim_task_board_workflow_side_effect(
                &TaskBoardWorkflowExecutionCas::from(&selected),
                &TaskBoardExecutionAttemptCas::from(&selected_attempt),
                &running,
                &running.updated_at,
            )
            .await
            .expect("claim selected local target")
            .is_some()
    );
    assert_eq!(assignment_count(&fixture).await, 0);
    assert_eq!(codex_run_count(&fixture).await, 0);
}

#[tokio::test]
async fn newer_host_revision_selects_one_local_disposition_without_remote_io() {
    let fixture = remote_controller_fixture(1).await;
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load newer controller settings");
    settings.step_mode = !settings.step_mode;
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("persist newer controller settings revision");
    refresh_fixture_observation(&fixture, 1, 0).await;
    let mut report = TaskBoardRemoteControllerReport::default();

    offer_remote_candidates(&fixture.db, &mut report)
        .await
        .expect("select local target for frozen older revision");
    let selected = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load frozen-revision selection")
        .expect("frozen-revision execution exists");
    assert_eq!(report.offered_attempts, 0);
    assert_eq!(selected.attempts[0].state, TaskBoardAttemptState::Starting);
    assert_eq!(
        selected
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .map(String::as_str),
        Some("local")
    );
    assert_eq!(assignment_count(&fixture).await, 0);
    assert_eq!(codex_run_count(&fixture).await, 0);

    let selected_cas = TaskBoardWorkflowExecutionCas::from(&selected);
    offer_remote_candidates(&fixture.db, &mut report)
        .await
        .expect("replay frozen-revision selection");
    let replayed = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("reload frozen-revision selection")
        .expect("frozen-revision execution still exists");
    assert_eq!(TaskBoardWorkflowExecutionCas::from(&replayed), selected_cas);
    assert_eq!(report.offered_attempts, 0);
    assert_eq!(assignment_count(&fixture).await, 0);
    assert_eq!(codex_run_count(&fixture).await, 0);
}

#[tokio::test]
async fn transient_progress_failure_defers_exact_generation_and_survives_restart() {
    let fixture = remote_controller_fixture(1).await;
    assert!(matches!(
        fixture
            .db
            .offer_task_board_remote_assignment(
                &TaskBoardWorkflowExecutionCas::from(&fixture.execution),
                &TaskBoardExecutionAttemptCas::from(&fixture.attempt),
                &fixture.request,
                &fixture.request.binding.host_id,
                "2026-07-19T10:00:00Z",
                "2026-07-19T10:01:00Z",
                &fixture.request.deadline_at,
            )
            .await
            .expect("offer transient-failure assignment"),
        TaskBoardRemoteOfferOutcome::Created(_)
    ));
    let failed_at = canonical_now();
    let step = fixture
        .db
        .next_task_board_remote_controller_assignment(&failed_at)
        .await
        .expect("select transient-failure assignment")
        .expect("transient-failure assignment is scan-visible");
    let TaskBoardRemoteControllerScanStep::Assignment(item) = step else {
        panic!("healthy assignment was unexpectedly quarantined before progression");
    };
    let mut report = TaskBoardRemoteControllerReport::default();
    super::scan::finish_progress_attempt(
        &fixture.db,
        &item,
        Err(CliErrorKind::workflow_io("executor status timed out").into()),
        &mut report,
    )
    .await
    .expect("defer transient controller failure");
    assert!(report.scan_blocked);
    assert_eq!(
        query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM task_board_remote_recovery_quarantine
             WHERE assignment_id = ?1 AND last_error_code = 'controller_progression'",
        )
        .bind(&fixture.request.binding.assignment_id)
        .fetch_one(fixture.db.pool())
        .await
        .expect("count exact transient quarantine"),
        1
    );

    let database_path = fixture._temp.path().join("controller.db");
    drop(fixture.db);
    let reopened = AsyncDaemonDb::connect(&database_path)
        .await
        .expect("reopen controller after transient failure");
    assert!(
        reopened
            .task_board_remote_controller_progression_is_blocked()
            .await
            .expect("load durable foreground progression gate")
    );
    assert!(
        reopened
            .next_task_board_remote_controller_assignment(&failed_at)
            .await
            .expect("scan during transient backoff")
            .is_none()
    );
    let retry_at =
        (Utc::now() + Duration::seconds(10)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let replay = reopened
        .next_task_board_remote_controller_assignment(&retry_at)
        .await
        .expect("scan after transient backoff")
        .expect("deferred exact generation becomes retryable");
    let TaskBoardRemoteControllerScanStep::Assignment(replay) = replay else {
        panic!("unchanged deferred generation did not decode on retry");
    };
    assert_eq!(
        replay.assignment.assignment_id,
        fixture.request.binding.assignment_id
    );
    let mut retry_report = TaskBoardRemoteControllerReport::default();
    super::scan::finish_progress_attempt(&reopened, &replay, Ok(false), &mut retry_report)
        .await
        .expect("complete exact deferred generation retry");
    assert!(
        !reopened
            .task_board_remote_controller_progression_is_blocked()
            .await
            .expect("load cleared foreground progression gate")
    );
}

async fn refresh_fixture_observation(
    fixture: &crate::daemon::db::RemoteControllerFixture,
    capacity: u32,
    active_assignments: u32,
) {
    let now = canonical_now();
    fixture
        .db
        .record_task_board_execution_host_observation(
            &TaskBoardExecutionHostAdvertisement {
                host_id: fixture.request.binding.host_id.clone(),
                host_instance_id: fixture.request.binding.host_instance_id.clone(),
                protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
                repositories: vec![fixture.request.source.repository().to_owned()],
                runtimes: vec![fixture.request.launch.runtime.clone()],
                capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
                capacity,
                active_assignments,
                heartbeat_at: now.clone(),
            },
            &now,
        )
        .await
        .expect("refresh fixture host observation");
}

async fn assignment_count(fixture: &crate::daemon::db::RemoteControllerFixture) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_remote_assignments WHERE execution_id = ?1")
        .bind(&fixture.execution.execution_id)
        .fetch_one(fixture.db.pool())
        .await
        .expect("count remote assignments")
}

async fn codex_run_count(fixture: &crate::daemon::db::RemoteControllerFixture) -> i64 {
    query_scalar("SELECT COUNT(*) FROM codex_runs")
        .fetch_one(fixture.db.pool())
        .await
        .expect("count local Codex runs")
}
