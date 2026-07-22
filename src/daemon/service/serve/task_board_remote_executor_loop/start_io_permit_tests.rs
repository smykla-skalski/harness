use super::disabled_tests::{
    EXECUTOR_INSTANCE, EXECUTOR_START_AT, claim_start_authority, codex_run_count,
    configure_checkout, executor_session_count, executor_state, git_repository,
    load_assignment, persist_exact_run, request_for_revision,
};
use super::source::install_remote_session_creation_barrier;
use super::{prepare_remote_workspace, reconcile_remote_executor_assignment};
use crate::daemon::db::{
    TaskBoardRemoteMutationOutcome, remote_executor_fixture, remote_executor_identity,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

#[tokio::test]
async fn settings_can_win_during_provisioning_and_force_exact_cleanup() {
    let fixture = remote_executor_fixture(1).await;
    let (origin, revision) = git_repository(fixture._temp.path());
    configure_checkout(&fixture.db, &origin).await;
    let request = request_for_revision(&fixture.request, &revision);
    let (accepted, authority) = claim_start_authority(&fixture, &request).await;
    let authorized = load_assignment(&fixture.db, &accepted.assignment_id).await;
    let identity = remote_executor_identity(&authorized).expect("remote executor identity");
    let barrier = install_remote_session_creation_barrier(&authority.sha256);
    let db = fixture.db.clone();
    let preparing_record = authorized.clone();
    let preparing_identity = identity.clone();
    let preparing = tokio::spawn(async move {
        prepare_remote_workspace(
            &db,
            &preparing_record,
            preparing_record.require_offer().expect("sealed offer"),
            &preparing_identity,
            true,
        )
        .await
    });
    barrier.wait_until_entered().await;
    assert_eq!(executor_session_count(&fixture.db).await, 1);
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings during provisioning");
    settings.local_execution_host.enabled = false;
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("reversible provisioning must not fence settings replacement");
    barrier.release().await;
    let error = preparing
        .await
        .expect("join blocked executor preparation")
        .expect_err("changed settings reject the prepared workspace");
    assert!(error.to_string().contains("settings changed"));
    reconcile_remote_executor_assignment(
        &executor_state(&fixture.db, EXECUTOR_INSTANCE),
        &fixture.db,
        &accepted.assignment_id,
    )
    .await
    .expect("settings winner cleans the deterministic workspace");
    let revoked = load_assignment(&fixture.db, &accepted.assignment_id).await;
    assert_eq!(revoked.state, TaskBoardRemoteAssignmentState::Unknown);
    assert!(revoked.executor_start_authority_sha256.is_none());
    assert!(revoked.executor_start_io_permit_sha256.is_none());
    assert_eq!(executor_session_count(&fixture.db).await, 0);
    assert_eq!(codex_run_count(&fixture.db).await, 0);
}

#[tokio::test]
async fn final_start_io_permit_fences_settings_until_adoption() {
    let fixture = remote_executor_fixture(1).await;
    let (origin, revision) = git_repository(fixture._temp.path());
    configure_checkout(&fixture.db, &origin).await;
    let request = request_for_revision(&fixture.request, &revision);
    let (accepted, authority) = claim_start_authority(&fixture, &request).await;
    let authorized = load_assignment(&fixture.db, &accepted.assignment_id).await;
    let identity = remote_executor_identity(&authorized).expect("remote executor identity");
    let workspace = prepare_remote_workspace(
        &fixture.db,
        &authorized,
        authorized.require_offer().expect("sealed offer"),
        &identity,
        true,
    )
    .await
    .expect("prepare exact executor workspace");
    let permit = fixture
        .db
        .claim_task_board_remote_executor_start_io_permit(
            &authority,
            &workspace,
            EXECUTOR_START_AT,
        )
        .await
        .expect("claim final Start I/O permit")
        .expect_acquired("Start remains permitted");
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings after permit");
    settings.local_execution_host.enabled = false;
    let error = fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect_err("final Start I/O permit must fence settings replacement");
    assert!(error.to_string().contains("owns Start I/O"));
    persist_exact_run(&fixture.db, &authorized, &authority, &workspace).await;
    assert!(matches!(
        fixture
            .db
            .adopt_task_board_remote_executor_start_owned(
                &permit,
                &workspace,
                EXECUTOR_START_AT,
                EXECUTOR_INSTANCE,
                EXECUTOR_START_AT,
            )
            .await
            .expect("adopt exact executor Start"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("adoption releases the settings replacement fence");
}
