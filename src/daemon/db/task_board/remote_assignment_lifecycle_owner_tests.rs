use std::path::Path;

use sqlx::query;
use tempfile::TempDir;

use super::remote_assignment_start_authority::executor_start_authority;
use super::remote_assignment_test_support::*;
use super::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorLifecycleOwner,
    TaskBoardRemoteExecutorStartIoPermit, TaskBoardRemoteMutationOutcome,
};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;
use crate::task_board::TaskBoardRemoteAssignmentState;

struct RestartedExecutor {
    db: AsyncDaemonDb,
    _temp: TempDir,
    request: RemoteOfferRequest,
    accepted: TaskBoardRemoteAssignmentRecord,
    authorized: TaskBoardRemoteAssignmentRecord,
    authority: TaskBoardRemoteExecutorStartIoPermit,
    project_dir: String,
}

#[tokio::test]
async fn start_authority_wins_expiry_recovery_and_survives_restart() {
    let restarted = prepare_restarted_executor().await;
    let owner = adopt_restarted_executor(&restarted).await;
    persist_normal_runtime_thread(&restarted, &owner).await;
    let successor = transfer_lifecycle_owner(&restarted, &owner).await;
    assert_old_owner_is_fenced(&restarted, &owner, &successor).await;
    assert_recovery_and_claim_replay(&restarted).await;
}

async fn persist_normal_runtime_thread(
    restarted: &RestartedExecutor,
    owner: &TaskBoardRemoteExecutorLifecycleOwner,
) {
    let updated = query("UPDATE codex_runs SET thread_id = 'thread-normal-start' WHERE run_id = ?1")
        .bind(&restarted.authority.identity.run_id)
        .execute(restarted.db.pool())
        .await
        .expect("persist normal Codex thread");
    assert_eq!(updated.rows_affected(), 1);
    let mut settings = restarted
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings before disable");
    settings.local_execution_host.enabled = false;
    restarted
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("disable executor without changing frozen launch material");
    let replayed = restarted
        .db
        .claim_task_board_remote_executor_lifecycle_owner(
            &restarted.accepted.assignment_id,
            &owner.owner_instance_id,
            "2026-07-19T10:02:10Z",
        )
        .await
        .expect("reclaim lifecycle owner after thread creation")
        .expect("normal thread preserves lifecycle owner");
    assert_eq!(replayed, *owner);
}

async fn prepare_restarted_executor() -> RestartedExecutor {
    let fixture = executor_fixture(1).await;
    let accepted = claim_executor(&fixture).await;
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &accepted.assignment_id,
            INSTANCE,
            STARTED_AT,
        )
        .await
        .expect("claim start authority")
        .expect("start authority");
    let authorized = load_assignment(&fixture, &accepted.assignment_id).await;
    assert_eq!(authorized.last_mutation_kind.as_deref(), Some("claim"));
    assert_eq!(
        authorized.executor_start_authority_sha256.as_deref(),
        Some(authority.sha256.as_str())
    );
    let (project_dir, permit) =
        persist_executor_run(&fixture, &authorized, &authority, STARTED_AT).await;
    assert_recovery_defers_owned_start(&fixture.db).await;

    let path = fixture._temp.path().join("executor.db");
    let request = fixture.request.clone();
    let temp = fixture._temp;
    drop(fixture.db);
    let db = AsyncDaemonDb::connect(&path).await.expect("restart executor DB");
    let scan = db
        .scan_task_board_remote_executor_assignments()
        .await
        .expect("scan predecessor executor generation");
    assert!(scan.active_assignment_ids.contains(&accepted.assignment_id));
    let reloaded = db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("reload token assignment")
        .expect("token assignment");
    assert_eq!(executor_start_authority(&reloaded).unwrap(), Some(authority.clone()));
    RestartedExecutor {
        db,
        _temp: temp,
        request,
        accepted,
        authorized,
        authority: permit,
        project_dir,
    }
}

async fn assert_recovery_defers_owned_start(db: &AsyncDaemonDb) {
    let recovered = db
        .recover_task_board_remote_assignments(AFTER_EXPIRY)
        .await
        .expect("recovery defers owned start");
    assert!(recovered.recovered.is_empty());
    assert!(recovered.failures.is_empty());
}

async fn adopt_restarted_executor(
    restarted: &RestartedExecutor,
) -> TaskBoardRemoteExecutorLifecycleOwner {
    let adopted = restarted
        .db
        .adopt_task_board_remote_executor_start_owned(
            &restarted.authority,
            Path::new(&restarted.project_dir),
            STARTED_AT,
            "instance-b",
            AFTER_EXPIRY,
        )
        .await
        .expect("adopt start after restart");
    let TaskBoardRemoteMutationOutcome::Updated(adopted) = adopted else {
        panic!("expected adopted executor start, got {adopted:?}");
    };
    assert_eq!(adopted.state, TaskBoardRemoteAssignmentState::Started);
    assert!(adopted.executor_start_authority_sha256.is_none());
    assert_eq!(adopted.last_mutation_kind.as_deref(), Some("claim"));
    assert_eq!(adopted.claimed_host_instance_id.as_deref(), Some(INSTANCE));
    let owner = adopted
        .executor_lifecycle_owner
        .expect("adopted lifecycle owner");
    assert_eq!(owner.owner_instance_id, "instance-b");
    owner
}

async fn transfer_lifecycle_owner(
    restarted: &RestartedExecutor,
    owner: &TaskBoardRemoteExecutorLifecycleOwner,
) -> TaskBoardRemoteExecutorLifecycleOwner {
    assert!(
        restarted
            .db
            .claim_task_board_remote_executor_lifecycle_owner(
                &restarted.accepted.assignment_id,
                "instance-c",
                "2026-07-19T10:02:20Z",
            )
            .await
            .expect("reject a live lifecycle owner transfer")
            .is_none()
    );
    let successor = restarted
        .db
        .claim_task_board_remote_executor_lifecycle_owner(
            &restarted.accepted.assignment_id,
            "instance-c",
            "2026-07-19T10:02:31Z",
        )
        .await
        .expect("transfer expired lifecycle owner")
        .expect("successor lifecycle owner");
    assert_eq!(successor.owner_epoch, owner.owner_epoch + 1);
    successor
}

async fn assert_old_owner_is_fenced(
    restarted: &RestartedExecutor,
    owner: &TaskBoardRemoteExecutorLifecycleOwner,
    successor: &TaskBoardRemoteExecutorLifecycleOwner,
) {
    assert!(matches!(
        restarted
            .db
            .mark_task_board_remote_assignment_running(
                &restarted.accepted.assignment_id,
                owner,
                "2026-07-19T10:02:32Z",
            )
            .await
            .expect("old owner loses running transition"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    assert!(matches!(
        restarted
            .db
            .mark_task_board_remote_assignment_running(
                &restarted.accepted.assignment_id,
                successor,
                "2026-07-19T10:02:32Z",
            )
            .await
            .expect("mark restarted exact worker running after expiry"),
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Running
    ));
}

async fn assert_recovery_and_claim_replay(restarted: &RestartedExecutor) {
    assert_recovery_defers_owned_start(&restarted.db).await;
    assert!(matches!(
        restarted
            .db
            .claim_task_board_remote_assignment(
                &claim_request(&restarted.request, &restarted.accepted),
                PRINCIPAL,
                CLAIMED_AT,
            )
            .await
            .expect("replay immutable claim after adoption"),
        TaskBoardRemoteMutationOutcome::Replayed(record)
            if record.state == TaskBoardRemoteAssignmentState::Running
                && record.authenticated_principal == restarted.authorized.authenticated_principal
                && record.claimed_at == restarted.authorized.claimed_at
                && record.claim_receipt == restarted.authorized.claim_receipt
    ));
}

async fn claim_executor(fixture: &ExecutorFixture) -> TaskBoardRemoteAssignmentRecord {
    let accepted = accept_executor(fixture, &fixture.request).await;
    assert!(matches!(
        fixture
            .db
            .claim_task_board_remote_assignment(
                &claim_request(&fixture.request, &accepted),
                PRINCIPAL,
                CLAIMED_AT,
            )
            .await
            .expect("claim executor assignment"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    accepted
}

async fn load_assignment(
    fixture: &ExecutorFixture,
    assignment_id: &str,
) -> TaskBoardRemoteAssignmentRecord {
    fixture
        .db
        .task_board_remote_assignment(assignment_id)
        .await
        .expect("load assignment")
        .expect("assignment")
}
