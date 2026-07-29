use std::path::PathBuf;

use chrono::{SecondsFormat, Utc};
use sqlx::query;

use super::disabled_tests::{
    EXECUTOR_INSTANCE, EXECUTOR_START_AT, SettingsDrift, claim_start_authority, codex_run_count,
    configure_checkout, drift_executor_settings, executor_state, git_repository, load_assignment,
    persist_exact_run, request_for_revision,
};
use super::{prepare_remote_workspace, reconcile_remote_executor_assignment};
use crate::daemon::db::{
    RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorStartIoPermit,
    TaskBoardRemoteExecutorStopAuthority, TaskBoardRemoteExecutorStopReason,
    TaskBoardRemoteMutationOutcome, remote_executor_fixture, remote_executor_identity,
};
use crate::daemon::protocol::CodexRunStatus;
use crate::task_board::TaskBoardRemoteAssignmentState;

#[tokio::test]
async fn compatible_settings_changes_reconcile_started_workers_through_terminal() {
    for drift in [SettingsDrift::Disabled, SettingsDrift::RevisionOnly] {
        for owner_instance in [EXECUTOR_INSTANCE, "restarted-instance"] {
            let (fixture, _, started, authority, _) = adopted_worker().await;
            drift_executor_settings(&fixture.db, drift).await;
            query("UPDATE codex_runs SET status = 'cancelled', updated_at = ?2 WHERE run_id = ?1")
                .bind(&authority.identity.run_id)
                .bind("2026-07-19T10:00:40Z")
                .execute(fixture.db.pool())
                .await
                .expect("persist terminal executor snapshot");
            let state = executor_state(&fixture.db, owner_instance);

            reconcile_remote_executor_assignment(&state, &fixture.db, &started.assignment_id)
                .await
                .expect("compatible changed settings preserve terminal reconciliation");

            let terminal = load_assignment(&fixture.db, &started.assignment_id).await;
            assert_eq!(terminal.state, TaskBoardRemoteAssignmentState::Failed);
            assert_eq!(codex_run_count(&fixture.db).await, 1);
            reconcile_remote_executor_assignment(&state, &fixture.db, &started.assignment_id)
                .await
                .expect("terminal restart replay performs no second executor mutation");
            assert_eq!(codex_run_count(&fixture.db).await, 1);
        }
    }
}

#[tokio::test]
async fn launch_material_drift_is_durable_stop_only_across_ambiguous_restart() {
    let (fixture, _, started, authority, old_checkout) = adopted_worker().await;
    let (replacement, _) = git_repository(&fixture._temp.path().join("replacement"));
    configure_checkout(&fixture.db, &replacement).await;
    let claim = fixture
        .db
        .claim_task_board_remote_executor_lifecycle_owner_with_settings(
            &started.assignment_id,
            "stop-owner",
            "2026-07-19T10:01:00Z",
        )
        .await
        .expect("claim lifecycle settings decision")
        .expect("expired owner transfers for stop-only reconciliation");
    assert!(claim.stop_only);
    let snapshot = fixture
        .db
        .codex_run(&authority.identity.run_id)
        .await
        .expect("load executor run")
        .expect("executor run");
    assert_eq!(
        snapshot.project_dir,
        old_checkout.to_string_lossy().into_owned()
    );
    let pending = fixture
        .db
        .claim_task_board_remote_executor_stop_pending(
            &TaskBoardRemoteExecutorStopAuthority::Lifecycle(claim.owner),
            &snapshot,
            TaskBoardRemoteExecutorStopReason::LifecycleEvidenceInvalid,
            "2026-07-19T10:01:01Z",
        )
        .await
        .expect("claim durable stop-only evidence")
        .expect("launch drift requires stop-only reconciliation");
    assert!(matches!(
        fixture
            .db
            .settle_task_board_remote_executor_stop_pending(
                &pending,
                "2026-07-19T10:01:02Z",
            )
            .await
            .expect("ambiguous active stop cannot settle"),
        TaskBoardRemoteMutationOutcome::Stale(ref record)
            if record.executor_stop_pending.as_ref() == Some(&pending)
    ));
    assert!(
        fixture
            .db
            .claim_task_board_remote_executor_lifecycle_owner(
                &started.assignment_id,
                "different-owner",
                "2026-07-19T10:02:00Z",
            )
            .await
            .expect("stop-pending owner replay")
            .is_none()
    );

    let state = executor_state(&fixture.db, "restarted-stop-owner");
    reconcile_remote_executor_assignment(&state, &fixture.db, &started.assignment_id)
        .await
        .expect("restart retries the exact stop without a new Start or adoption");
    let stopped = load_assignment(&fixture.db, &started.assignment_id).await;
    assert_eq!(stopped.state, TaskBoardRemoteAssignmentState::Unknown);
    assert!(stopped.executor_stop_pending.is_none());
    assert_eq!(codex_run_count(&fixture.db).await, 1);
}

// A lifecycle-owner takeover cannot resume a worker the prior generation
// started: that worker is an in-process task of the now-gone daemon, so it is
// detached from the successor's controller. The successor fails it closed
// rather than reporting phantom progress no daemon is driving, and a stale
// non-owner cannot act at all. Resuming an inherited worker in place is a
// separate future capability (executor takeover resume), out of scope here.
#[tokio::test]
async fn post_adoption_replay_requires_the_current_lifecycle_owner() {
    let (fixture, _claimed, started, _authority, _workspace) = adopted_worker().await;
    let identity = remote_executor_identity(&started).expect("remote executor identity");
    // The successor acquires ownership on the same whole-second clock the
    // reconcile loop reads, so the monotonic-owner fence sees a stable owner
    // rather than one whose acquisition appears to sit in the future.
    let owner_b = fixture
        .db
        .claim_task_board_remote_executor_lifecycle_owner(
            &started.assignment_id,
            "owner-b",
            &crate::workspace::utc_now(),
        )
        .await
        .expect("claim successor lifecycle owner")
        .expect("expired initial owner transfers to B");

    // A stale would-be successor cannot borrow the live owner's lifecycle: its
    // reconcile no-ops and never probes, leaving the durable worker untouched.
    let stale_state = executor_state(&fixture.db, "owner-a");
    reconcile_remote_executor_assignment(&stale_state, &fixture.db, &started.assignment_id)
        .await
        .expect("stale reconcile cannot borrow the live owner");
    let unchanged = load_assignment(&fixture.db, &started.assignment_id).await;
    assert_eq!(unchanged.state, TaskBoardRemoteAssignmentState::Started);
    assert_eq!(unchanged.executor_lifecycle_owner.as_ref(), Some(&owner_b));
    assert_eq!(
        fixture
            .db
            .codex_run(&identity.run_id)
            .await
            .expect("load worker")
            .expect("worker")
            .status,
        CodexRunStatus::Running,
        "a fenced stale reconcile must not touch the durable worker",
    );

    // The current owner reconciles the inherited, now-detached worker to a safe
    // terminal, launching no second Start.
    let owner_b_state = executor_state(&fixture.db, "owner-b");
    reconcile_remote_executor_assignment(&owner_b_state, &fixture.db, &started.assignment_id)
        .await
        .expect("the current owner reconciles the detached worker to a safe terminal");
    let terminal = load_assignment(&fixture.db, &started.assignment_id).await;
    assert_eq!(terminal.state, TaskBoardRemoteAssignmentState::Failed);
    assert_eq!(codex_run_count(&fixture.db).await, 1);

    // Replay under the same owner performs no second executor mutation.
    reconcile_remote_executor_assignment(&owner_b_state, &fixture.db, &started.assignment_id)
        .await
        .expect("terminal replay performs no second executor mutation");
    assert_eq!(
        load_assignment(&fixture.db, &started.assignment_id)
            .await
            .state,
        TaskBoardRemoteAssignmentState::Failed,
    );
    assert_eq!(codex_run_count(&fixture.db).await, 1);
}

#[tokio::test]
async fn lifecycle_owner_takeover_waits_for_the_exact_expiry() {
    let (fixture, _, started, _, _) = adopted_worker().await;
    let owner_at = Utc::now().to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let owner_b = fixture
        .db
        .claim_task_board_remote_executor_lifecycle_owner(
            &started.assignment_id,
            "owner-b",
            &owner_at,
        )
        .await
        .expect("claim B lifecycle owner")
        .expect("B owns the expired initial generation");
    assert!(
        fixture
            .db
            .claim_task_board_remote_executor_lifecycle_owner(
                &started.assignment_id,
                "owner-a",
                &owner_at,
            )
            .await
            .expect("check live B owner")
            .is_none()
    );
    let owner_a = fixture
        .db
        .claim_task_board_remote_executor_lifecycle_owner(
            &started.assignment_id,
            "owner-a",
            &owner_b.expires_at,
        )
        .await
        .expect("claim owner after exact expiry")
        .expect("A takes over only after B expires");
    assert_eq!(owner_a.owner_epoch, owner_b.owner_epoch + 1);
}

async fn adopted_worker() -> (
    RemoteExecutorFixture,
    TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteExecutorStartIoPermit,
    PathBuf,
) {
    let fixture = remote_executor_fixture(1).await;
    let (origin, revision) = git_repository(fixture._temp.path());
    configure_checkout(&fixture.db, &origin).await;
    let request = request_for_revision(&fixture.request, &revision);
    let (accepted, authority) = claim_start_authority(&fixture, &request).await;
    let claimed = load_assignment(&fixture.db, &accepted.assignment_id).await;
    let identity = remote_executor_identity(&claimed).expect("remote executor identity");
    let workspace = prepare_remote_workspace(
        &fixture.db,
        &claimed,
        claimed.require_offer().expect("sealed offer"),
        &identity,
        true,
    )
    .await
    .expect("prepare exact executor workspace");
    let authority = fixture
        .db
        .authorize_task_board_remote_executor_provisioning(&authority, EXECUTOR_START_AT)
        .await
        .expect("authorize exact Start I/O")
        .expect("unchanged settings authorize Start");
    let permit = fixture
        .db
        .claim_task_board_remote_executor_start_io_permit(&authority, &workspace, EXECUTOR_START_AT)
        .await
        .expect("claim exact Start I/O permit")
        .expect_acquired("unchanged settings permit Start");
    persist_exact_run(&fixture.db, &claimed, &authority, &workspace).await;
    let started = match fixture
        .db
        .adopt_task_board_remote_executor_start_owned(
            &permit,
            &workspace,
            EXECUTOR_START_AT,
            EXECUTOR_INSTANCE,
            EXECUTOR_START_AT,
        )
        .await
        .expect("adopt exact enabled executor start")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        outcome => panic!("unexpected start adoption: {outcome:?}"),
    };
    assert_eq!(started.state, TaskBoardRemoteAssignmentState::Started);
    assert_eq!(
        fixture
            .db
            .codex_run(&permit.identity.run_id)
            .await
            .expect("load adopted run")
            .expect("adopted run")
            .status,
        CodexRunStatus::Running
    );
    (fixture, claimed, started, permit, workspace)
}
