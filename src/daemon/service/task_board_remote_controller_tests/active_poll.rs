use std::future::ready;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::daemon::db::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteControllerOperationToken,
    TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome, remote_controller_fixture,
};
use crate::task_board::{
    TaskBoardExecutionAttemptCas, TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas,
};

#[tokio::test]
async fn due_active_poll_observes_completed_and_failed_before_renewal() {
    for terminal in [
        TaskBoardRemoteAssignmentState::Completed,
        TaskBoardRemoteAssignmentState::Failed,
    ] {
        let assignment = active_assignment("2026-07-19T10:00:30Z").await;
        let terminal_record = record_in_state(&assignment, terminal);
        let renewal_record = assignment.clone();
        let replay_record = assignment.clone();
        let status_calls = Arc::new(AtomicUsize::new(0));
        let renew_calls = Arc::new(AtomicUsize::new(0));
        let status_probe = Arc::clone(&status_calls);
        let renew_probe = Arc::clone(&renew_calls);

        super::super::poll_active_assignment_with(
            &assignment,
            move |_| {
                status_probe.fetch_add(1, Ordering::SeqCst);
                ready(Ok(TaskBoardRemoteMutationOutcome::Updated(terminal_record)))
            },
            || ready(Ok(true)),
            move |_| {
                renew_probe.fetch_add(1, Ordering::SeqCst);
                ready(Ok(TaskBoardRemoteMutationOutcome::Updated(renewal_record)))
            },
            move |_| ready(Ok(TaskBoardRemoteMutationOutcome::Updated(replay_record))),
            || "2026-07-19T10:00:30Z".into(),
        )
        .await
        .expect("observe terminal executor status before due renewal");

        assert_eq!(status_calls.load(Ordering::SeqCst), 1);
        assert_eq!(renew_calls.load(Ordering::SeqCst), 0);
    }
}

#[tokio::test]
async fn disabled_active_poll_observes_status_without_renewal() {
    let assignment = active_assignment("2026-07-19T10:00:30Z").await;
    let running = assignment.clone();
    let renewal_record = assignment.clone();
    let replay_record = assignment.clone();
    let status_calls = Arc::new(AtomicUsize::new(0));
    let renew_calls = Arc::new(AtomicUsize::new(0));
    let status_probe = Arc::clone(&status_calls);
    let renew_probe = Arc::clone(&renew_calls);

    super::super::poll_active_assignment_with(
        &assignment,
        move |_| {
            status_probe.fetch_add(1, Ordering::SeqCst);
            ready(Ok(TaskBoardRemoteMutationOutcome::Updated(running)))
        },
        || ready(Ok(false)),
        move |_| {
            renew_probe.fetch_add(1, Ordering::SeqCst);
            ready(Ok(TaskBoardRemoteMutationOutcome::Updated(renewal_record)))
        },
        move |_| ready(Ok(TaskBoardRemoteMutationOutcome::Updated(replay_record))),
        || "2026-07-19T10:00:30Z".into(),
    )
    .await
    .expect("observe active disabled executor without renewal");

    assert_eq!(status_calls.load(Ordering::SeqCst), 1);
    assert_eq!(renew_calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn active_poll_uses_fresh_post_status_time_for_renewal() {
    let assignment = active_assignment("2026-07-19T10:01:00Z").await;
    assert!(
        !super::super::requests::renewal_is_due(&assignment, "2026-07-19T10:00:20Z")
            .expect("evaluate earlier cycle time")
    );
    let running = assignment.clone();
    let renewed = assignment.clone();
    let replay_record = assignment.clone();
    let renew_calls = Arc::new(AtomicUsize::new(0));
    let renew_probe = Arc::clone(&renew_calls);

    super::super::poll_active_assignment_with(
        &assignment,
        move |_| ready(Ok(TaskBoardRemoteMutationOutcome::Updated(running))),
        || ready(Ok(true)),
        move |_| {
            renew_probe.fetch_add(1, Ordering::SeqCst);
            ready(Ok(TaskBoardRemoteMutationOutcome::Updated(renewed)))
        },
        move |_| ready(Ok(TaskBoardRemoteMutationOutcome::Updated(replay_record))),
        || "2026-07-19T10:00:31Z".into(),
    )
    .await
    .expect("renew from fresh post-status time");

    assert_eq!(renew_calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn pending_cancel_observes_status_without_renewal() {
    let mut assignment = active_assignment("2026-07-19T10:00:30Z").await;
    assignment.controller_operation = Some(operation("cancel"));
    let running = assignment.clone();
    let renewal_record = assignment.clone();
    let replay_record = assignment.clone();
    let renew_calls = Arc::new(AtomicUsize::new(0));
    let renew_probe = Arc::clone(&renew_calls);

    super::super::poll_active_assignment_with(
        &assignment,
        move |_| ready(Ok(TaskBoardRemoteMutationOutcome::Updated(running))),
        || ready(Ok(true)),
        move |_| {
            renew_probe.fetch_add(1, Ordering::SeqCst);
            ready(Ok(TaskBoardRemoteMutationOutcome::Updated(renewal_record)))
        },
        move |_| ready(Ok(TaskBoardRemoteMutationOutcome::Updated(replay_record))),
        || "2026-07-19T10:00:30Z".into(),
    )
    .await
    .expect("observe pending cancellation before renewal");

    assert_eq!(renew_calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn disabled_pending_renew_replays_before_status() {
    let mut assignment = active_assignment("2026-07-19T10:00:30Z").await;
    assignment.controller_operation = Some(operation("renew"));
    let mut renewed = assignment.clone();
    renewed.controller_operation = None;
    let status_record = renewed.clone();
    let stage = Arc::new(AtomicUsize::new(0));
    let status_stage = Arc::clone(&stage);
    let renew_stage = Arc::clone(&stage);
    let ordinary_renewal = assignment.clone();

    super::super::poll_active_assignment_with(
        &assignment,
        move |_| {
            assert_eq!(status_stage.load(Ordering::SeqCst), 1);
            status_stage.store(2, Ordering::SeqCst);
            ready(Ok(TaskBoardRemoteMutationOutcome::Updated(status_record)))
        },
        || ready(Ok(false)),
        move |_| ready(Ok(TaskBoardRemoteMutationOutcome::Stale(ordinary_renewal))),
        move |_| {
            assert_eq!(renew_stage.load(Ordering::SeqCst), 0);
            renew_stage.store(1, Ordering::SeqCst);
            ready(Ok(TaskBoardRemoteMutationOutcome::Updated(renewed)))
        },
        || "2026-07-19T10:00:30Z".into(),
    )
    .await
    .expect("replay pending renewal before status");

    assert_eq!(stage.load(Ordering::SeqCst), 2);
}

async fn active_assignment(lease_expires_at: &str) -> TaskBoardRemoteAssignmentRecord {
    let fixture = remote_controller_fixture(1).await;
    // The offer lease must equal offered_at + sealed lease_seconds; the in-memory expiry
    // is overridden below to drive each test's renewal-timing scenario.
    let mut assignment = match fixture
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
        .expect("create active-poll assignment")
    {
        TaskBoardRemoteOfferOutcome::Created(record) => record,
        other => panic!("expected new active-poll assignment, got {other:?}"),
    };
    assignment.state = TaskBoardRemoteAssignmentState::Running;
    assignment.authenticated_principal = Some(fixture.request.binding.host_id.clone());
    assignment.claimed_host_instance_id = Some(fixture.request.binding.host_instance_id.clone());
    assignment.claimed_at = Some("2026-07-19T10:00:05Z".into());
    assignment.started_at = Some("2026-07-19T10:00:10Z".into());
    assignment.workspace_ref = Some("workspace-active-poll".into());
    assignment.lease_id = Some("lease-active-poll".into());
    assignment.lease_expires_at = Some(lease_expires_at.into());
    assignment
}

fn record_in_state(
    assignment: &TaskBoardRemoteAssignmentRecord,
    state: TaskBoardRemoteAssignmentState,
) -> TaskBoardRemoteAssignmentRecord {
    let mut record = assignment.clone();
    record.state = state;
    record
}

fn operation(kind: &str) -> TaskBoardRemoteControllerOperationToken {
    TaskBoardRemoteControllerOperationToken {
        kind: kind.into(),
        request_sha256: "a".repeat(64),
        trust_sha256: "b".repeat(64),
        fence: None,
    }
}
