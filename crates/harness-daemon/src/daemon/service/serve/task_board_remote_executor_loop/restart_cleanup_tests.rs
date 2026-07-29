use std::path::PathBuf;

use super::disabled_tests::{
    EXECUTOR_INSTANCE, SettingsDrift, claim_start_authority, codex_run_count, configure_checkout,
    drift_executor_settings, executor_session_count, executor_state, git_repository,
    load_assignment, request_for_revision,
};
use super::{prepare_remote_workspace, reconcile_remote_executor_assignment};
use crate::daemon::db::{
    RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorStartAuthority,
    remote_executor_fixture, remote_executor_identity,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

const SUCCESSOR_INSTANCE: &str = "instance-b";

#[tokio::test]
async fn successor_cleans_predecessor_session_before_revoking_start_permit() {
    let (fixture, accepted, authority, workspace) = predecessor_partial_workspace().await;
    let session_root = workspace.parent().expect("session root").to_path_buf();
    assert_eq!(executor_session_count(&fixture.db).await, 1);

    reconcile_remote_executor_assignment(
        &executor_state(&fixture.db, SUCCESSOR_INSTANCE),
        &fixture.db,
        &accepted.assignment_id,
    )
    .await
    .expect("successor performs cleanup-only reconciliation");

    assert_predecessor_cleanup(&fixture, &accepted.assignment_id, &session_root).await;
    assert!(authority.identity.run_id.starts_with("remote-codex-"));
    drift_executor_settings(&fixture.db, SettingsDrift::Disabled).await;
    reconcile_remote_executor_assignment(
        &executor_state(&fixture.db, SUCCESSOR_INSTANCE),
        &fixture.db,
        &accepted.assignment_id,
    )
    .await
    .expect("successor cleanup replays without Start or adoption");
    assert_eq!(codex_run_count(&fixture.db).await, 0);
}

#[tokio::test]
async fn successor_cleans_rowless_predecessor_workspace_before_revoking_start_permit() {
    let (fixture, accepted, authority, workspace) = predecessor_partial_workspace().await;
    let session_root = workspace.parent().expect("session root").to_path_buf();
    assert!(
        fixture
            .db
            .delete_session_row(&authority.identity.session_id)
            .await
            .expect("delete crash-gap session row")
    );
    assert!(session_root.exists());
    assert_eq!(executor_session_count(&fixture.db).await, 0);

    reconcile_remote_executor_assignment(
        &executor_state(&fixture.db, SUCCESSOR_INSTANCE),
        &fixture.db,
        &accepted.assignment_id,
    )
    .await
    .expect("successor removes deterministic rowless workspace before token revocation");

    assert_predecessor_cleanup(&fixture, &accepted.assignment_id, &session_root).await;
    assert_eq!(executor_session_count(&fixture.db).await, 0);
}

async fn predecessor_partial_workspace() -> (
    RemoteExecutorFixture,
    TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteExecutorStartAuthority,
    PathBuf,
) {
    let fixture = remote_executor_fixture(1).await;
    let (origin, revision) = git_repository(fixture._temp.path());
    configure_checkout(&fixture.db, &origin).await;
    let request = request_for_revision(&fixture.request, &revision);
    let (accepted, authority) = claim_start_authority(&fixture, &request).await;
    let claimed = load_assignment(&fixture.db, &accepted.assignment_id).await;
    let identity = remote_executor_identity(&claimed).expect("remote executor identity");
    assert_eq!(
        claimed.claimed_host_instance_id.as_deref(),
        Some(EXECUTOR_INSTANCE)
    );
    let workspace = prepare_remote_workspace(
        &fixture.db,
        &claimed,
        claimed.require_offer().expect("sealed offer"),
        &identity,
        true,
    )
    .await
    .expect("persist predecessor partial workspace");
    (fixture, accepted, authority, workspace)
}

async fn assert_predecessor_cleanup(
    fixture: &RemoteExecutorFixture,
    assignment_id: &str,
    session_root: &std::path::Path,
) {
    let cleaned = load_assignment(&fixture.db, assignment_id).await;
    assert_eq!(cleaned.state, TaskBoardRemoteAssignmentState::Unknown);
    assert_eq!(
        cleaned.error.as_deref(),
        Some("remote executor restarted before worker start")
    );
    assert!(cleaned.executor_start_authority_sha256.is_none());
    assert!(cleaned.start_receipt.is_none());
    assert!(!session_root.exists());
    assert_eq!(codex_run_count(&fixture.db).await, 0);
}
