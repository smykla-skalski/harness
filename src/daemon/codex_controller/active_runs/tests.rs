use std::sync::Barrier;

use crate::daemon::protocol::{CodexRunMode, CodexRunStatus};

use super::*;

fn snapshot(run_id: &str) -> CodexRunSnapshot {
    CodexRunSnapshot {
        run_id: run_id.to_string(),
        session_id: "session-1".to_string(),
        task_id: None,
        board_item_id: None,
        workflow_execution_id: None,
        session_agent_id: None,
        display_name: Some("Codex".to_string()),
        project_dir: "/tmp/project".to_string(),
        thread_id: None,
        turn_id: None,
        mode: CodexRunMode::Report,
        status: CodexRunStatus::Queued,
        prompt: "investigate".to_string(),
        latest_summary: Some("queued".to_string()),
        final_message: None,
        error: None,
        pending_approvals: Vec::new(),
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: "2026-07-11T00:00:00Z".to_string(),
        updated_at: "2026-07-11T00:00:00Z".to_string(),
        model: None,
        effort: None,
    }
}

fn acquired(registration: ActiveRunRegistration) -> ActiveRunReservation {
    match registration {
        ActiveRunRegistration::Acquired(reservation) => reservation,
        ActiveRunRegistration::Waiting(_) | ActiveRunRegistration::Active => {
            panic!("expected startup reservation")
        }
    }
}

fn waiting(registration: ActiveRunRegistration) -> ActiveRunWaiter {
    match registration {
        ActiveRunRegistration::Waiting(waiter) => waiter,
        ActiveRunRegistration::Acquired(_) | ActiveRunRegistration::Active => {
            panic!("expected startup waiter")
        }
    }
}

#[test]
fn duplicate_reservation_waits_for_the_persisted_snapshot() {
    let active_runs = ActiveRuns::default();
    let reservation = acquired(
        active_runs
            .reserve("durable-run".to_string())
            .expect("reserve first startup"),
    );
    let waiter = waiting(
        active_runs
            .reserve("durable-run".to_string())
            .expect("observe existing startup"),
    );
    let expected = snapshot("durable-run");
    let (finished_tx, finished_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        finished_tx
            .send(waiter.wait())
            .expect("report duplicate result");
    });

    assert!(
        finished_rx.recv_timeout(Duration::from_millis(20)).is_err(),
        "duplicate must wait until the first snapshot is persisted"
    );
    let (control_tx, _control_rx) = mpsc::unbounded_channel();
    reservation
        .commit(control_tx, expected.clone())
        .expect("complete first startup");
    let actual = finished_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("duplicate was released")
        .expect("first startup succeeded");
    assert_eq!(actual.run_id, expected.run_id);
    assert_eq!(actual.updated_at, expected.updated_at);
}

#[test]
fn concurrent_reservations_have_exactly_one_owner() {
    let active_runs = ActiveRuns::default();
    let barrier = Arc::new(Barrier::new(8));
    let (result_tx, result_rx) = std::sync::mpsc::channel();
    let mut threads = Vec::new();
    for _ in 0..8 {
        let active_runs = active_runs.clone();
        let barrier = Arc::clone(&barrier);
        let result_tx = result_tx.clone();
        threads.push(std::thread::spawn(move || {
            barrier.wait();
            let result = active_runs
                .reserve("shared-run".to_string())
                .expect("reserve shared run");
            result_tx.send(result).expect("send registration");
        }));
    }
    drop(result_tx);
    for thread in threads {
        thread.join().expect("reservation thread");
    }
    let registrations: Vec<_> = result_rx.into_iter().collect();
    assert_eq!(
        registrations
            .iter()
            .filter(|registration| matches!(registration, ActiveRunRegistration::Acquired(_)))
            .count(),
        1
    );
    assert_eq!(
        registrations
            .iter()
            .filter(|registration| matches!(registration, ActiveRunRegistration::Waiting(_)))
            .count(),
        7
    );
}

#[test]
fn committed_control_sender_cannot_be_replaced_by_duplicate_reservation() {
    let active_runs = ActiveRuns::default();
    let reservation = acquired(
        active_runs
            .reserve("active-run".to_string())
            .expect("reserve startup"),
    );
    let (control_tx, mut control_rx) = mpsc::unbounded_channel();
    reservation
        .commit(control_tx, snapshot("active-run"))
        .expect("commit startup");
    assert!(matches!(
        active_runs
            .reserve("active-run".to_string())
            .expect("reserve active run"),
        ActiveRunRegistration::Active
    ));
    let (ack, _ack_rx) = oneshot::channel();
    active_runs
        .get("active-run")
        .expect("active run")
        .control_tx
        .send(CodexControlMessage::Stop { ack })
        .expect("send through committed channel");
    assert!(matches!(
        control_rx.try_recv(),
        Ok(CodexControlMessage::Stop { .. })
    ));
}

#[test]
fn failed_reservation_notifies_waiters_and_releases_the_identity() {
    let active_runs = ActiveRuns::default();
    let reservation = acquired(
        active_runs
            .reserve("retryable-run".to_string())
            .expect("reserve first startup"),
    );
    let waiter = waiting(
        active_runs
            .reserve("retryable-run".to_string())
            .expect("observe existing startup"),
    );
    let startup_error: CliError = CliErrorKind::workflow_io("startup failed").into();

    reservation.abort(&startup_error);

    assert!(
        waiter
            .wait()
            .expect_err("duplicate must observe startup failure")
            .to_string()
            .contains("startup failed")
    );
    assert!(matches!(
        active_runs
            .reserve("retryable-run".to_string())
            .expect("reserve retry"),
        ActiveRunRegistration::Acquired(_)
    ));
}

#[test]
fn abandoned_reservation_notifies_waiters_and_releases_the_identity() {
    let active_runs = ActiveRuns::default();
    let reservation = acquired(
        active_runs
            .reserve("abandoned-run".to_string())
            .expect("reserve startup"),
    );
    let waiter = waiting(
        active_runs
            .reserve("abandoned-run".to_string())
            .expect("observe startup"),
    );

    drop(reservation);

    assert!(
        waiter
            .wait()
            .expect_err("waiter must observe abandonment")
            .to_string()
            .contains("abandoned")
    );
    assert!(!active_runs.contains("abandoned-run"));
}

#[test]
fn poisoned_registry_abort_still_notifies_waiters() {
    let active_runs = ActiveRuns::default();
    let reservation = acquired(
        active_runs
            .reserve("poisoned-run".to_string())
            .expect("reserve startup"),
    );
    let waiter = waiting(
        active_runs
            .reserve("poisoned-run".to_string())
            .expect("observe startup"),
    );
    active_runs.poison_for_test();
    let startup_error: CliError = CliErrorKind::workflow_io("startup failed after poison").into();

    reservation.abort(&startup_error);

    assert!(
        waiter
            .wait()
            .expect_err("waiter must observe startup failure")
            .to_string()
            .contains("startup failed after poison")
    );
}

#[test]
fn removing_a_reservation_prevents_commit_and_wakes_waiters() {
    let active_runs = ActiveRuns::default();
    let reservation = acquired(
        active_runs
            .reserve("removed-run".to_string())
            .expect("reserve startup"),
    );
    let waiter = waiting(
        active_runs
            .reserve("removed-run".to_string())
            .expect("observe startup"),
    );

    active_runs.remove("removed-run");
    let (control_tx, _control_rx) = mpsc::unbounded_channel();
    assert!(
        reservation
            .commit(control_tx, snapshot("removed-run"))
            .expect_err("removed reservation must not commit")
            .to_string()
            .contains("lost its startup reservation")
    );
    assert!(
        waiter
            .wait()
            .expect_err("waiter must observe removal")
            .to_string()
            .contains("removed before startup completed")
    );
    assert!(!active_runs.contains("removed-run"));
}

#[test]
fn waiter_timeout_does_not_release_the_owner() {
    let active_runs = ActiveRuns::default();
    let reservation = acquired(
        active_runs
            .reserve("slow-run".to_string())
            .expect("reserve startup"),
    );
    let waiter = waiting(
        active_runs
            .reserve("slow-run".to_string())
            .expect("observe startup"),
    );

    assert!(
        waiter
            .wait_with_timeout(Duration::from_millis(1))
            .expect_err("waiter should time out")
            .to_string()
            .contains("did not complete")
    );
    assert!(active_runs.contains("slow-run"));
    drop(reservation);
}
