use std::net::SocketAddr;

use super::fixture::{
    AcceptanceFixture, HOST_INSTANCE, SeededExecution, TlsRouterServer, assignment,
};
use super::lifecycle::{
    assert_executor_runtime_presence, drive, executor_assignment, offer_and_claim,
    reconcile_executor_tick, run_deep_acceptance_async, with_acceptance_environment,
};
use crate::daemon::db::remote_executor_identity;
use crate::daemon::task_board_remote_transport::controller_authority_test_support::{
    TestTlsMaterial, test_tls_material,
};
use crate::task_board::{TaskBoardExecutionState, TaskBoardRemoteAssignmentState};

#[test]
fn claimed_execution_settles_safely_after_two_daemon_restart() {
    run_deep_acceptance_async(|| async {
        let tls = test_tls_material();
        with_acceptance_environment(
            &tls,
            "remote-acceptance-restarted-lifecycle",
            run_restarted_lifecycle(&tls),
        )
        .await;
    });
}

struct ClaimedRestartBoundary {
    seeded: SeededExecution,
    assignment_id: String,
    endpoint: String,
    bound_address: SocketAddr,
    controller_assignment: crate::daemon::db::TaskBoardRemoteAssignmentRecord,
    executor_assignment: crate::daemon::db::TaskBoardRemoteAssignmentRecord,
}

async fn run_restarted_lifecycle(tls: &TestTlsMaterial) {
    let fixture = AcceptanceFixture::new();
    let restart = reach_durable_claim_and_stop_old_daemons(&fixture, tls).await;
    let controller = fixture.controller_state("controller-acceptance-b");
    let executor = fixture.executor_state("executor-acceptance-b", false).await;
    let server =
        TlsRouterServer::start_at(restart.bound_address, executor.clone(), tls.server_config())
            .await;
    assert_eq!(server.endpoint(), restart.endpoint);
    let controller_db = controller.async_db.get().expect("reopened controller db");
    let executor_db = executor.async_db.get().expect("reopened executor db");
    assert_eq!(
        assignment(controller_db, &restart.seeded.execution_id).await,
        restart.controller_assignment
    );
    assert_eq!(
        executor_assignment(executor_db, &restart.assignment_id).await,
        restart.executor_assignment
    );
    reconcile_executor_tick(&executor, "settle predecessor claim after restart").await;
    let unknown = executor_assignment(executor_db, &restart.assignment_id).await;
    assert_restarted_prestart_unknown(executor_db, &unknown).await;
    drive(controller_db, "observe restarted executor Unknown").await;
    drive(controller_db, "settle restarted executor Unknown").await;
    reconcile_executor_tick(&executor, "clean up restarted executor Unknown").await;
    drive(controller_db, "observe restarted executor cleanup").await;
    assert_restarted_unknown_completion(
        controller_db,
        executor_db,
        &restart.seeded.execution_id,
        &restart.assignment_id,
    )
    .await;
    server.stop().await;
}

async fn reach_durable_claim_and_stop_old_daemons(
    fixture: &AcceptanceFixture,
    tls: &TestTlsMaterial,
) -> ClaimedRestartBoundary {
    let executor = fixture.executor_state(HOST_INSTANCE, true).await;
    let server = TlsRouterServer::start(executor.clone(), tls.server_config()).await;
    let controller = fixture.controller_state("controller-acceptance-a");
    fixture
        .configure_controller(&controller, server.endpoint(), tls)
        .await;
    let controller_db = controller.async_db.get().expect("controller db");
    let seeded = fixture.seed_default_task(controller_db).await;
    let controller_assignment = offer_and_claim(controller_db, &seeded.execution_id).await;
    let executor_db = executor.async_db.get().expect("executor database");
    let executor_assignment =
        executor_assignment(executor_db, &controller_assignment.assignment_id).await;
    assert_pre_executor_tick_boundary(executor_db, &executor_assignment).await;
    let restart = ClaimedRestartBoundary {
        seeded,
        assignment_id: controller_assignment.assignment_id.clone(),
        endpoint: server.endpoint().into(),
        bound_address: server.bound_address(),
        controller_assignment,
        executor_assignment,
    };
    server.stop().await;
    drop(executor);
    drop(controller);
    restart
}

async fn assert_pre_executor_tick_boundary(
    db: &crate::daemon::db::AsyncDaemonDb,
    record: &crate::daemon::db::TaskBoardRemoteAssignmentRecord,
) {
    assert_eq!(record.state, TaskBoardRemoteAssignmentState::Claimed);
    assert!(
        record.executor_start_authority_sha256.is_none()
            && record.executor_start_io_permit_sha256.is_none()
            && record.start_receipt.is_none()
            && record.workspace_ref.is_none()
            && record.started_at.is_none()
    );
    let identity = remote_executor_identity(record).expect("executor identity before first tick");
    assert_executor_runtime_presence(db, &identity, false).await;
}

async fn assert_restarted_prestart_unknown(
    db: &crate::daemon::db::AsyncDaemonDb,
    record: &crate::daemon::db::TaskBoardRemoteAssignmentRecord,
) {
    assert_eq!(record.state, TaskBoardRemoteAssignmentState::Unknown);
    assert_eq!(
        record.error.as_deref(),
        Some("remote executor restarted before worker start")
    );
    assert!(record.start_receipt.is_none() && record.workspace_ref.is_none());
    let identity = remote_executor_identity(record).expect("restarted executor identity");
    assert_executor_runtime_presence(db, &identity, false).await;
    assert!(
        db.resolve_session(&identity.session_id)
            .await
            .expect("load restarted executor session")
            .is_none()
    );
}

async fn assert_restarted_unknown_completion(
    controller_db: &crate::daemon::db::AsyncDaemonDb,
    executor_db: &crate::daemon::db::AsyncDaemonDb,
    execution_id: &str,
    assignment_id: &str,
) {
    let controller = assignment(controller_db, execution_id).await;
    let executor = executor_assignment(executor_db, assignment_id).await;
    assert_eq!(controller.state, TaskBoardRemoteAssignmentState::Unknown);
    assert!(controller.cleanup_completed_at.is_some());
    assert!(executor.cleanup_completed_at.is_some());
    let parent = controller_db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("load restarted controller execution")
        .expect("restarted controller execution exists");
    assert_eq!(
        parent.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert!(
        parent
            .attempts
            .iter()
            .any(|attempt| { attempt.state == crate::task_board::TaskBoardAttemptState::Unknown })
    );
}
