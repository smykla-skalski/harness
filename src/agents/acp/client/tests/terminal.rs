//! Terminal handler tests.

use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use agent_client_protocol::schema::{
    CreateTerminalRequest, KillTerminalRequest, ReleaseTerminalRequest, TerminalOutputRequest,
    WaitForTerminalExitRequest,
};

use crate::agents::acp::client::TERMINAL_DENIED;

use super::{read_log, setup_client, setup_recording_client};

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

#[test]
fn terminal_wait_on_one_terminal_does_not_block_output_for_another() {
    let (_temp, client) = setup_client();
    let client = Arc::new(client);

    let slow = client
        .handle_create_terminal(
            &CreateTerminalRequest::new("test-session", "sh")
                .args(vec!["-c".to_string(), "sleep 2".to_string()]),
        )
        .expect("create slow terminal")
        .terminal_id;
    let quick = client
        .handle_create_terminal(
            &CreateTerminalRequest::new("test-session", "sh")
                .args(vec!["-c".to_string(), "printf quick".to_string()]),
        )
        .expect("create quick terminal")
        .terminal_id;

    let wait_client = Arc::clone(&client);
    let wait_terminal = slow.clone();
    let wait_thread = thread::spawn(move || {
        wait_client.handle_wait_for_terminal_exit(&WaitForTerminalExitRequest::new(
            "test-session",
            wait_terminal,
        ))
    });

    thread::sleep(Duration::from_millis(100));

    let start = Instant::now();
    let output = client
        .handle_terminal_output(&TerminalOutputRequest::new("test-session", quick.clone()))
        .expect("terminal output");

    assert!(
        start.elapsed() < Duration::from_secs(1),
        "wait on one terminal must not block output from another"
    );
    assert!(output.output.contains("quick"), "{output:?}");

    wait_thread
        .join()
        .expect("wait thread")
        .expect("wait terminal");
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
    let (_temp, client) = setup_client();

    for i in 0..16 {
        let request = CreateTerminalRequest::new("test-session", "echo").args(vec![format!("{i}")]);
        let result = client.handle_create_terminal(&request);
        assert!(result.is_ok(), "terminal {i} should succeed");
    }

    let request = CreateTerminalRequest::new("test-session", "echo").args(vec!["17".to_string()]);
    let result = client.handle_create_terminal(&request);

    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code, TERMINAL_DENIED);
    assert!(err.message.contains("cap"));
}
