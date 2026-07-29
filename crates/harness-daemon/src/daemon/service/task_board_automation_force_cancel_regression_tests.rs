use super::task_board_automation_force_cancel::{
    AuditOutcome, apply_cancel, audit_event, force_cancel_task_board_automation_db,
};
use crate::daemon::db::{
    accept_remote_controller, claim_remote_controller, remote_controller_fixture,
    remote_controller_running_status, remote_controller_status_request,
};
use crate::daemon::protocol::{
    HarnessMonitorAuditEventsRequest, TaskBoardAutomationForceCancelRequest,
};
use crate::feature_flags::TASK_BOARD_AUTOMATION_V2_ENV;
use crate::task_board::{TaskBoardAutomationDesiredMode, TaskBoardRemoteAssignmentState};

const REASON: &str = "operator requested exact remote cancellation";

#[tokio::test]
async fn claimed_to_started_race_leaves_force_cancel_mutations_unwritten() {
    let fixture = remote_controller_fixture(1).await;
    initialize_automation_control(&fixture.db).await;
    let offered = accept_remote_controller(&fixture).await;
    let claimed = claim_remote_controller(&fixture, &offered).await;
    let target = fixture
        .db
        .task_board_automation_cancel_target(&fixture.execution.execution_id)
        .await
        .expect("load claimed target")
        .expect("claimed target exists");
    let status_request = remote_controller_status_request(&fixture.request, &claimed);
    assert!(
        fixture
            .db
            .claim_task_board_remote_status_io_authority(&status_request, &claimed.host_id)
            .await
            .expect("claim running status authority")
    );
    fixture
        .db
        .record_task_board_remote_assignment_status(
            &status_request,
            &remote_controller_running_status(&status_request, &claimed),
            &claimed.host_id,
        )
        .await
        .expect("record running status");
    let running = fixture
        .db
        .task_board_remote_assignment(&claimed.assignment_id)
        .await
        .expect("load running assignment")
        .expect("running assignment exists");
    assert!(matches!(
        running.state,
        TaskBoardRemoteAssignmentState::Started | TaskBoardRemoteAssignmentState::Running
    ));
    let before = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load workflow after running status")
        .expect("running workflow exists");
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("change sequence after running status");
    let audit = audit_event(
        &TaskBoardAutomationForceCancelRequest {
            target: target.clone(),
            reason: REASON.into(),
            actor: Some("test operator".into()),
        },
        AuditOutcome::Success,
    );

    let error = apply_cancel(&fixture.db, before.clone(), &target, REASON, &audit)
        .await
        .expect_err("running generation must reject the claimed target");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(
        fixture
            .db
            .task_board_workflow_execution(&before.execution_id)
            .await
            .expect("reload workflow")
            .expect("workflow exists"),
        before
    );
    assert_eq!(
        fixture
            .db
            .task_board_remote_assignment(&claimed.assignment_id)
            .await
            .expect("reload running assignment")
            .expect("running assignment exists"),
        running
    );
    assert_eq!(
        fixture
            .db
            .current_change_sequence()
            .await
            .expect("change sequence"),
        sequence
    );
    assert!(force_cancel_events(&fixture.db).await.is_empty());
}

#[tokio::test]
async fn feature_off_force_cancel_leaves_workflow_change_and_audit_untouched() {
    let fixture = remote_controller_fixture(1).await;
    initialize_automation_control(&fixture.db).await;
    let offered = accept_remote_controller(&fixture).await;
    claim_remote_controller(&fixture, &offered).await;
    let before = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load workflow")
        .expect("workflow exists");
    let target = fixture
        .db
        .task_board_automation_cancel_target(&before.execution_id)
        .await
        .expect("load target")
        .expect("target exists");
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("change sequence");
    let request = TaskBoardAutomationForceCancelRequest {
        target,
        reason: REASON.into(),
        actor: Some("test operator".into()),
    };

    temp_env::async_with_vars([(TASK_BOARD_AUTOMATION_V2_ENV, Some("0"))], async {
        let error = force_cancel_task_board_automation_db(&fixture.db, &request)
            .await
            .expect_err("feature-off force cancel must reject");
        assert_eq!(error.code(), "KSRCLI084");
    })
    .await;
    assert_eq!(
        fixture
            .db
            .task_board_workflow_execution(&before.execution_id)
            .await
            .expect("reload workflow")
            .expect("workflow exists"),
        before
    );
    assert_eq!(
        fixture
            .db
            .current_change_sequence()
            .await
            .expect("change sequence"),
        sequence
    );
    assert!(force_cancel_events(&fixture.db).await.is_empty());
}

async fn force_cancel_events(
    db: &crate::daemon::db::AsyncDaemonDb,
) -> Vec<crate::daemon::protocol::HarnessMonitorAuditEvent> {
    db.load_audit_events(&HarnessMonitorAuditEventsRequest {
        action_keys: vec!["task_board.automation.execution.force_cancel".into()],
        ..HarnessMonitorAuditEventsRequest::default()
    })
    .await
    .expect("load force-cancel audit events")
    .events
}

async fn initialize_automation_control(db: &crate::daemon::db::AsyncDaemonDb) {
    db.initialize_task_board_automation_control_from_legacy_intent(
        TaskBoardAutomationDesiredMode::Off,
        chrono::Utc::now(),
    )
    .await
    .expect("initialize automation control");
}
