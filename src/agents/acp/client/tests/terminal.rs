//! Terminal handler tests.

use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use agent_client_protocol::schema::{
    CreateTerminalRequest, KillTerminalRequest, ReleaseTerminalRequest, TerminalId,
    TerminalOutputRequest, WaitForTerminalExitRequest,
};

use crate::agents::acp::client::{HarnessAcpClient, TERMINAL_DENIED};

use super::{read_log, setup_client, setup_client_with_terminal_cap, setup_recording_client};

#[test]
fn terminal_denied_binary_rejected() {
    let (_temp, client) = setup_client();

    let request = CreateTerminalRequest::new("test-session", "kubectl");
    let result = client.handle_create_terminal(&request);

    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code, TERMINAL_DENIED);
}

#[test]
fn recording_terminal_logs_denial_without_changing_runtime_decision() {
    let (_temp, client, log_path) = setup_recording_client();
    let request = CreateTerminalRequest::new("session-1", "kubectl");

    let error = client
        .handle_create_terminal(&request)
        .expect_err("terminal denied");

    assert_eq!(error.code, TERMINAL_DENIED);
    let records = read_log(&log_path);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["operation"], "terminal.create");
    assert_eq!(records[0]["decision"], "denied");
    assert_eq!(records[0]["wouldAsk"]["command"], "kubectl");
}

#[test]
fn terminal_denied_binary_path_rejected_by_basename() {
    let (_temp, client) = setup_client();

    let request = CreateTerminalRequest::new("test-session", "/usr/local/bin/kubectl");
    let result = client.handle_create_terminal(&request);

    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code, TERMINAL_DENIED);
}

#[test]
fn terminal_denied_binary_rejected_through_common_wrappers() {
    let (_temp, client) = setup_client();

    let shell = CreateTerminalRequest::new("test-session", "sh")
        .args(vec!["-c".to_string(), "exec kubectl get pods".to_string()]);
    let env = CreateTerminalRequest::new("test-session", "env").args(vec![
        "KUBECONFIG=/tmp/config".to_string(),
        "kubectl".to_string(),
    ]);

    assert_eq!(
        client
            .handle_create_terminal(&shell)
            .expect_err("shell wrapper should be denied")
            .code,
        TERMINAL_DENIED
    );
    assert_eq!(
        client
            .handle_create_terminal(&env)
            .expect_err("env wrapper should be denied")
            .code,
        TERMINAL_DENIED
    );
}

#[test]
fn terminal_output_for_running_process_returns_promptly() {
    let (_temp, client) = setup_client();

    let create = CreateTerminalRequest::new("test-session", "sh")
        .args(vec!["-c".to_string(), "printf ready; sleep 2".to_string()]);
    let terminal = client
        .handle_create_terminal(&create)
        .expect("create terminal")
        .terminal_id;

    let start = Instant::now();
    let output = client
        .handle_terminal_output(&TerminalOutputRequest::new(
            "test-session",
            terminal.clone(),
        ))
        .expect("terminal output");

    assert!(
        start.elapsed() < Duration::from_secs(1),
        "terminal/output must not block on a live process"
    );
    assert!(output.exit_status.is_none());

    client
        .handle_kill_terminal(&KillTerminalRequest::new("test-session", terminal))
        .expect("kill terminal");
}

#[test]
fn terminal_wait_then_output_returns_exit_status_and_output() {
    let (_temp, client) = setup_client();

    let create = CreateTerminalRequest::new("test-session", "sh")
        .args(vec!["-c".to_string(), "printf hello".to_string()]);
    let terminal = client
        .handle_create_terminal(&create)
        .expect("create terminal")
        .terminal_id;

    let wait = client
        .handle_wait_for_terminal_exit(&WaitForTerminalExitRequest::new(
            "test-session",
            terminal.clone(),
        ))
        .expect("wait terminal");
    assert_eq!(wait.exit_status.exit_code, Some(0));

    let output = client
        .handle_terminal_output(&TerminalOutputRequest::new("test-session", terminal))
        .expect("terminal output");

    assert!(output.output.contains("hello"), "{output:?}");
    assert_eq!(output.exit_status, Some(wait.exit_status));
}

// Read a terminal's buffer until `needle` appears, so an assertion never races
// the background PTY reader. A wall-clock sleep would false-fail under a
// saturated `test:unit` run; polling the real buffer settles as soon as the
// reader flushes, and the deadline is only a safety net against a hung reader.
fn read_terminal_until_contains(client: &HarnessAcpClient, terminal: &TerminalId, needle: &str) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let output = client
            .handle_terminal_output(&TerminalOutputRequest::new(
                "test-session",
                terminal.clone(),
            ))
            .expect("terminal output");
        if output.output.contains(needle) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "terminal never produced {needle:?}"
        );
        thread::yield_now();
    }
}

#[test]
fn terminal_wait_on_one_terminal_does_not_block_output_for_another() {
    let (temp, client) = setup_client();
    let client = Arc::new(client);
    let shell = if cfg!(unix) { "/bin/sh" } else { "sh" };

    // The slow terminal blocks on a gate file the test controls, so the wait
    // below stays outstanding until the test releases it. This replaces the old
    // wall-clock budget (which false-fails when the suite saturates the CPU) with
    // an ordering check: reading a second terminal must return while the wait on
    // `slow` is still outstanding.
    let gate = temp.path().join("slow-terminal-gate");
    let gate_script = format!("until [ -e '{}' ]; do sleep 0.02; done", gate.display());
    let slow = client
        .handle_create_terminal(
            &CreateTerminalRequest::new("test-session", shell)
                .args(vec!["-c".to_string(), gate_script]),
        )
        .expect("create slow terminal")
        .terminal_id;
    let quick = client
        .handle_create_terminal(
            &CreateTerminalRequest::new("test-session", shell)
                .args(vec!["-c".to_string(), "printf quick".to_string()]),
        )
        .expect("create quick terminal")
        .terminal_id;

    // Settle the quick buffer before the ordering assertion reads it.
    read_terminal_until_contains(&client, &quick, "quick");

    // Put the wait on the slow terminal in flight, then block until the wait
    // handler itself reports that it has registered before blocking. This is an
    // explicit event from the real handler, not a sleep: it guarantees the wait
    // is outstanding (and, under a reintroduced shared lock, that the lock is
    // held) before we probe `quick`, so the ordering check cannot false-green on
    // a waiter that has not entered the wait path yet.
    let started_before = client.terminal_wait_started_count();
    let finished_before = client.terminal_wait_finished_count();
    let wait_client = Arc::clone(&client);
    let wait_terminal = slow.clone();
    let wait_thread = thread::spawn(move || {
        wait_client.handle_wait_for_terminal_exit(&WaitForTerminalExitRequest::new(
            "test-session",
            wait_terminal,
        ))
    });
    assert!(
        client.await_terminal_wait_started(started_before + 1, Duration::from_secs(10)),
        "wait handler never registered as started"
    );

    // Deadlock guard only: once the wait is registered, a regression that
    // serializes the read below behind the outstanding wait would block it. Open
    // the gate after a grace so the wait unwinds and the test fails as a bounded
    // assertion instead of hanging. The oracle is the ordering assertion below,
    // never this timeout; the fixed path cancels it the moment the read returns.
    let (cancel_tx, cancel_rx) = mpsc::channel::<()>();
    let gate_path = gate.clone();
    let releaser = thread::spawn(move || {
        if cancel_rx.recv_timeout(Duration::from_secs(5)).is_err() {
            let _ = std::fs::File::create(&gate_path);
        }
    });

    let output = client
        .handle_terminal_output(&TerminalOutputRequest::new("test-session", quick.clone()))
        .expect("terminal output");

    // Causal oracle: the wait records its finish before its handler releases, so
    // if reading `quick` had serialized behind that wait the count would have
    // advanced by the time the read returns. An unchanged count proves the read
    // overtook the still-outstanding wait. This is independent of wall-clock
    // timing and of the deadlock guard.
    assert_eq!(
        client.terminal_wait_finished_count(),
        finished_before,
        "output for another terminal serialized behind the outstanding wait"
    );
    assert!(output.output.contains("quick"), "{output:?}");

    // Release the slow terminal and unwind every helper thread.
    let _ = cancel_tx.send(());
    std::fs::File::create(&gate).expect("open slow gate");
    wait_thread
        .join()
        .expect("wait thread")
        .expect("wait terminal");
    releaser.join().expect("releaser thread");
    client
        .handle_release_terminal(&ReleaseTerminalRequest::new("test-session", slow))
        .expect("release slow terminal");
    client
        .handle_release_terminal(&ReleaseTerminalRequest::new("test-session", quick))
        .expect("release quick terminal");
}

#[test]
fn terminal_wait_returns_when_background_child_keeps_pty_open() {
    let (_temp, client) = setup_client();

    let terminal = client
        .handle_create_terminal(
            &CreateTerminalRequest::new("test-session", "sh")
                .args(vec!["-c".to_string(), "sleep 1 & exit 0".to_string()]),
        )
        .expect("create terminal")
        .terminal_id;

    let start = Instant::now();
    client
        .handle_wait_for_terminal_exit(&WaitForTerminalExitRequest::new(
            "test-session",
            terminal.clone(),
        ))
        .expect("wait terminal");

    assert!(
        start.elapsed() < Duration::from_secs(1),
        "wait should not block on the detached PTY reader"
    );

    client
        .handle_release_terminal(&ReleaseTerminalRequest::new("test-session", terminal))
        .expect("release terminal");
}

#[test]
#[cfg(unix)]
fn terminal_release_kills_background_child_that_ignores_sigterm() {
    let (temp, client) = setup_client();
    let leaked = temp.path().join("artifacts/should-not-exist.txt");
    let script = format!(
        "sh -c 'trap \"\" TERM; sleep 1; printf leaked > \"{}\"' & exit 0",
        leaked.display()
    );

    let terminal = client
        .handle_create_terminal(
            &CreateTerminalRequest::new("test-session", "sh").args(vec!["-c".to_string(), script]),
        )
        .expect("create terminal")
        .terminal_id;

    client
        .handle_wait_for_terminal_exit(&WaitForTerminalExitRequest::new(
            "test-session",
            terminal.clone(),
        ))
        .expect("wait terminal");
    client
        .handle_release_terminal(&ReleaseTerminalRequest::new("test-session", terminal))
        .expect("release terminal");

    thread::sleep(Duration::from_millis(1200));
    assert!(
        !leaked.exists(),
        "release should kill lingering background descendants"
    );
}

#[test]
fn terminal_cap_enforced() {
    let (_temp, client) = setup_client_with_terminal_cap(1);

    let request = CreateTerminalRequest::new("test-session", "echo").args(vec!["1".to_string()]);
    let terminal = client
        .handle_create_terminal(&request)
        .expect("first terminal should succeed")
        .terminal_id;

    let request = CreateTerminalRequest::new("test-session", "echo").args(vec!["2".to_string()]);
    let result = client.handle_create_terminal(&request);

    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code, TERMINAL_DENIED);
    assert!(err.message.contains("cap"));

    client
        .handle_release_terminal(&ReleaseTerminalRequest::new("test-session", terminal))
        .expect("release terminal");
}
