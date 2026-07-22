//! Production-loop proofs for the executor Start-I/O permit state machine:
//! explicit Acquired/Replayed/Stale outcomes, and the crash-boundary guarantee
//! that a durable permit never launches a second Start or reprovisions - even
//! when the session/workspace went missing.

use std::{future::Future, path::PathBuf, time::Duration};

use super::disabled_tests::{
    EXECUTOR_INSTANCE, EXECUTOR_START_AT, claim_start_authority, codex_run_count,
    configure_checkout, executor_session_count, executor_state, git_repository, load_assignment,
    persist_exact_run, request_for_revision,
};
use super::source::install_remote_session_creation_barrier;
use super::{
    prepare_remote_workspace, reconcile_remote_executor_assignment,
    spawn_task_board_remote_executor_loop, test_seam,
};
use crate::daemon::db::{
    REMOTE_EXECUTOR_PRINCIPAL, RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteExecutorIdentity, TaskBoardRemoteExecutorStartAuthority,
    TaskBoardRemoteExecutorStartIoPermitOutcome, TaskBoardRemoteMutationOutcome,
    TaskBoardRemoteOfferOutcome, remote_executor_claim_request, remote_executor_fixture,
    remote_executor_identity,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteSettledRequest, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{TaskBoardFailureClass, TaskBoardRemoteAssignmentState};
use chrono::{Duration as ChronoDuration, SecondsFormat, Utc};
use tokio::sync::watch;

#[path = "start_permit_state_machine_tests/shutdown.rs"]
mod shutdown;

/// A remote executor generation with a durable start authority and an exact
/// provisioned session, poised at the Start-I/O permit boundary.
struct ProvisionedAuthority {
    fixture: RemoteExecutorFixture,
    accepted: TaskBoardRemoteAssignmentRecord,
    authority: TaskBoardRemoteExecutorStartAuthority,
    identity: TaskBoardRemoteExecutorIdentity,
    workspace: PathBuf,
}

async fn provisioned_authority() -> ProvisionedAuthority {
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
    ProvisionedAuthority {
        fixture,
        accepted,
        authority,
        identity,
        workspace,
    }
}

#[tokio::test]
async fn start_io_permit_claim_is_acquired_then_replayed_and_stale_is_explicit() {
    let staged = provisioned_authority().await;
    // A permit time before authority acquisition can never acquire: explicit Stale.
    let stale = staged
        .fixture
        .db
        .claim_task_board_remote_executor_start_io_permit(
            &staged.authority,
            &staged.workspace,
            "2026-07-19T10:00:15Z",
        )
        .await
        .expect("claim rejects an early permit");
    assert_eq!(stale, TaskBoardRemoteExecutorStartIoPermitOutcome::Stale);

    // The first exact claim acquires and durably persists the permit.
    let acquired = staged
        .fixture
        .db
        .claim_task_board_remote_executor_start_io_permit(
            &staged.authority,
            &staged.workspace,
            EXECUTOR_START_AT,
        )
        .await
        .expect("claim acquires the Start I/O permit")
        .expect_acquired("first exact claim acquires");

    // Reopening the exact claim replays the identical durable permit, never a
    // second Acquired: only Acquired may drive a fresh external Start.
    let replayed = staged
        .fixture
        .db
        .claim_task_board_remote_executor_start_io_permit(
            &staged.authority,
            &staged.workspace,
            EXECUTOR_START_AT,
        )
        .await
        .expect("claim replays the Start I/O permit")
        .expect_replayed("reopening the exact claim replays");
    assert_eq!(
        replayed, acquired,
        "a replayed permit must be byte-identical to the acquired permit"
    );
}

#[test]
fn persisted_permit_without_a_run_converges_after_restart_and_releases_capacity() {
    run_deep_async(persisted_permit_without_a_run_converges_body);
}

async fn persisted_permit_without_a_run_converges_body() {
    let staged = provisioned_authority().await;
    // Acquire and persist the permit, then model a crash before the deterministic
    // run row landed: the permit is durable but no run exists.
    let _permit = staged
        .fixture
        .db
        .claim_task_board_remote_executor_start_io_permit(
            &staged.authority,
            &staged.workspace,
            EXECUTOR_START_AT,
        )
        .await
        .expect("claim acquires the Start I/O permit")
        .expect_acquired("acquire the crash-boundary permit");
    assert_eq!(executor_session_count(&staged.fixture.db).await, 1);
    assert_eq!(codex_run_count(&staged.fixture.db).await, 0);

    test_seam::reset_counters();
    reconcile_remote_executor_assignment(
        &executor_state(&staged.fixture.db, "restarted-instance"),
        &staged.fixture.db,
        &staged.accepted.assignment_id,
    )
    .await
    .expect("restart seals the proven no-run failure without executor I/O");

    assert_no_recovery_io();
    assert_eq!(codex_run_count(&staged.fixture.db).await, 0);
    assert_eq!(executor_session_count(&staged.fixture.db).await, 1);
    let failed = load_assignment(&staged.fixture.db, &staged.accepted.assignment_id).await;
    assert_failed_at_claimed(&failed);
    let failure_receipt = failed
        .executor_start_failure_receipt_sha256
        .clone()
        .expect("durable no-run failure receipt");

    reconcile_remote_executor_assignment(
        &executor_state(&staged.fixture.db, "second-restarted-instance"),
        &staged.fixture.db,
        &staged.accepted.assignment_id,
    )
    .await
    .expect("terminal failure replays without a new Start");
    assert_no_recovery_io();
    let replayed = load_assignment(&staged.fixture.db, &staged.accepted.assignment_id).await;
    assert_eq!(
        replayed.executor_start_failure_receipt_sha256.as_deref(),
        Some(failure_receipt.as_str())
    );

    settle_terminal(&staged.fixture, &failed, RemoteAssignmentWireState::Failed).await;
    assert_eq!(active_assignment_count(&staged.fixture).await, 1);
    reconcile_remote_executor_assignment(
        &executor_state(&staged.fixture.db, "cleanup-instance"),
        &staged.fixture.db,
        &staged.accepted.assignment_id,
    )
    .await
    .expect("settled Failed-at-Claimed record cleans provisioned capacity");
    let cleaned = load_assignment(&staged.fixture.db, &staged.accepted.assignment_id).await;
    assert_eq!(cleaned.state, TaskBoardRemoteAssignmentState::Failed);
    assert!(cleaned.cleanup_completed_at.is_some());
    assert_eq!(active_assignment_count(&staged.fixture).await, 0);
    assert_eq!(executor_session_count(&staged.fixture.db).await, 0);
    assert_eq!(codex_run_count(&staged.fixture.db).await, 0);
    assert!(!staged.workspace.exists());
}

#[test]
fn persisted_permit_with_missing_session_converges_without_recreation() {
    run_deep_async(persisted_permit_with_missing_session_converges_body);
}

async fn persisted_permit_with_missing_session_converges_body() {
    let staged = provisioned_authority().await;
    let _permit = staged
        .fixture
        .db
        .claim_task_board_remote_executor_start_io_permit(
            &staged.authority,
            &staged.workspace,
            EXECUTOR_START_AT,
        )
        .await
        .expect("claim acquires the Start I/O permit")
        .expect_acquired("acquire before the session vanishes");
    // The provisioned session vanishes between the permit and any run row.
    staged
        .fixture
        .db
        .delete_session_row(&staged.identity.session_id)
        .await
        .expect("drop the executor session row");
    assert_eq!(executor_session_count(&staged.fixture.db).await, 0);

    test_seam::reset_counters();
    reconcile_remote_executor_assignment(
        &executor_state(&staged.fixture.db, "restarted-instance"),
        &staged.fixture.db,
        &staged.accepted.assignment_id,
    )
    .await
    .expect("restart seals a no-run failure without recreating provisioning");

    assert_no_recovery_io();
    assert_eq!(
        executor_session_count(&staged.fixture.db).await,
        0,
        "the missing session must not be recreated"
    );
    assert_eq!(codex_run_count(&staged.fixture.db).await, 0);
    let failed = load_assignment(&staged.fixture.db, &staged.accepted.assignment_id).await;
    assert_failed_at_claimed(&failed);

    reconcile_remote_executor_assignment(
        &executor_state(&staged.fixture.db, "second-restarted-instance"),
        &staged.fixture.db,
        &staged.accepted.assignment_id,
    )
    .await
    .expect("failed no-run recovery replays without recreation");
    assert_no_recovery_io();
    assert_eq!(executor_session_count(&staged.fixture.db).await, 0);

    settle_terminal(&staged.fixture, &failed, RemoteAssignmentWireState::Failed).await;
    reconcile_remote_executor_assignment(
        &executor_state(&staged.fixture.db, "cleanup-instance"),
        &staged.fixture.db,
        &staged.accepted.assignment_id,
    )
    .await
    .expect("settled missing-session failure cleans deterministic workspace");
    assert_eq!(active_assignment_count(&staged.fixture).await, 0);
    assert_eq!(executor_session_count(&staged.fixture.db).await, 0);
    assert!(!staged.workspace.exists());
}

#[tokio::test]
async fn valid_pre_permit_run_stops_without_adoption_after_restart() {
    let staged = provisioned_authority().await;
    let claimed = load_assignment(&staged.fixture.db, &staged.accepted.assignment_id).await;
    persist_exact_run(
        &staged.fixture.db,
        &claimed,
        &staged.authority,
        &staged.workspace,
    )
    .await;

    test_seam::reset_counters();
    reconcile_remote_executor_assignment(
        &executor_state(&staged.fixture.db, "restarted-instance"),
        &staged.fixture.db,
        &staged.accepted.assignment_id,
    )
    .await
    .expect("pre-permit run receives an exact stop-only settlement");
    assert_no_recovery_io();
    let stopped = load_assignment(&staged.fixture.db, &staged.accepted.assignment_id).await;
    assert_eq!(stopped.state, TaskBoardRemoteAssignmentState::Unknown);
    assert!(stopped.start_receipt.is_none());
    assert!(stopped.executor_stop_pending.is_none());
    assert!(stopped.executor_start_authority_sha256.is_none());
    assert!(
        !staged
            .fixture
            .db
            .codex_run(&staged.identity.run_id)
            .await
            .expect("load stopped pre-permit run")
            .expect("pre-permit run remains as stopped evidence")
            .status
            .is_active(),
        "pre-permit stop leaves only terminal run evidence"
    );

    reconcile_remote_executor_assignment(
        &executor_state(&staged.fixture.db, "second-restarted-instance"),
        &staged.fixture.db,
        &staged.accepted.assignment_id,
    )
    .await
    .expect("terminal pre-permit stop replays without adoption");
    assert_no_recovery_io();
    let replayed = load_assignment(&staged.fixture.db, &staged.accepted.assignment_id).await;
    assert_eq!(replayed.state, TaskBoardRemoteAssignmentState::Unknown);
    assert!(replayed.start_receipt.is_none());
}

#[tokio::test]
async fn unattached_active_run_converges_to_terminal_failure_after_restart() {
    let staged = provisioned_authority().await;
    let permit = staged
        .fixture
        .db
        .claim_task_board_remote_executor_start_io_permit(
            &staged.authority,
            &staged.workspace,
            EXECUTOR_START_AT,
        )
        .await
        .expect("claim exact Start I/O permit")
        .expect_acquired("persist exact recovery permit");
    let claimed = load_assignment(&staged.fixture.db, &staged.accepted.assignment_id).await;
    persist_exact_run(
        &staged.fixture.db,
        &claimed,
        &staged.authority,
        &staged.workspace,
    )
    .await;

    test_seam::reset_counters();
    reconcile_remote_executor_assignment(
        &executor_state(&staged.fixture.db, "restarted-instance"),
        &staged.fixture.db,
        &staged.accepted.assignment_id,
    )
    .await
    .expect("controller reconciliation terminalizes the unattached active run");
    assert_no_recovery_io();
    let terminal = load_assignment(&staged.fixture.db, &staged.accepted.assignment_id).await;
    assert_eq!(terminal.state, TaskBoardRemoteAssignmentState::Failed);
    assert!(terminal.executor_start_io_permit_sha256.is_none());
    assert!(terminal.executor_start_authority_sha256.is_none());
    assert_eq!(
        terminal.workspace_ref.as_deref(),
        Some(permit.identity.workspace_ref.as_str())
    );
    assert!(terminal.start_receipt.is_some());
    assert_eq!(
        terminal
            .status_response
            .as_ref()
            .and_then(|status| status.error_code.as_deref()),
        Some("executor_runtime_failed")
    );
    assert_eq!(
        staged
            .fixture
            .db
            .codex_run(&staged.identity.run_id)
            .await
            .expect("load terminalized run")
            .expect("deterministic run remains as terminal evidence")
            .status,
        crate::daemon::protocol::CodexRunStatus::Failed
    );

    reconcile_remote_executor_assignment(
        &executor_state(&staged.fixture.db, "second-restarted-instance"),
        &staged.fixture.db,
        &staged.accepted.assignment_id,
    )
    .await
    .expect("terminal evidence replays without fresh executor I/O");
    assert_no_recovery_io();
    assert_eq!(
        load_assignment(&staged.fixture.db, &staged.accepted.assignment_id)
            .await
            .status_response,
        terminal.status_response
    );
}

fn assert_no_recovery_io() {
    assert_eq!(
        test_seam::start_calls(),
        0,
        "recovery must never launch a fresh Start"
    );
    assert_eq!(
        test_seam::provision_calls(),
        0,
        "recovery must never reprovision the deterministic session"
    );
}

fn assert_failed_at_claimed(record: &TaskBoardRemoteAssignmentRecord) {
    assert_eq!(record.state, TaskBoardRemoteAssignmentState::Failed);
    assert_eq!(
        record.error.as_deref(),
        Some("remote_start_interrupted_without_run")
    );
    assert!(record.executor_start_authority_sha256.is_none());
    assert!(record.executor_start_io_permit_sha256.is_none());
    assert!(record.start_receipt.is_none());
    assert!(record.executor_start_failure_receipt_sha256.is_some());
    assert_eq!(
        record
            .status_response
            .as_ref()
            .and_then(|status| status.failure_class),
        Some(TaskBoardFailureClass::Transient)
    );
}

async fn settle_terminal(
    fixture: &RemoteExecutorFixture,
    record: &TaskBoardRemoteAssignmentRecord,
    terminal_state: RemoteAssignmentWireState,
) {
    let offer = record.require_offer().expect("sealed terminal offer");
    let settlement = RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: record.lease_id.clone().expect("terminal lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal exact terminal settlement");
    fixture
        .db
        .settle_task_board_remote_assignment(
            &settlement,
            REMOTE_EXECUTOR_PRINCIPAL,
            EXECUTOR_START_AT,
        )
        .await
        .expect("persist immutable terminal settlement");
}

async fn active_assignment_count(fixture: &RemoteExecutorFixture) -> u32 {
    fixture
        .db
        .task_board_remote_executor_active_assignment_count("executor-a")
        .await
        .expect("count executor capacity")
}

fn run_deep_async<F>(build: impl FnOnce() -> F + Send + 'static)
where
    F: Future<Output = ()>,
{
    std::thread::Builder::new()
        .stack_size(32 * 1024 * 1024)
        .spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build deep test runtime")
                .block_on(build());
        })
        .expect("spawn deep test thread")
        .join()
        .expect("join deep test thread");
}
