use std::collections::BTreeSet;
use std::sync::{Arc, Barrier, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use agent_client_protocol::schema::{
    CreateTerminalRequest, KillTerminalRequest, TerminalExitStatus, TerminalOutputRequest,
    WaitForTerminalExitRequest,
};

use super::output::{append_with_limit, wait_for_output_drain};
use super::{TerminalLifecycleWait, TerminalManager, TerminalOutputState, TerminalWaitSignal};
use crate::agents::acp::client::TERMINAL_DENIED;
use crate::agents::policy::DeniedBinaries;

#[test]
fn append_with_limit_preserves_split_utf8_until_response_conversion() {
    let output = Mutex::new(TerminalOutputState {
        output: Vec::new(),
        truncated: false,
        output_limit: 8,
    });
    let euro = "€".as_bytes();

    append_with_limit(&output, &euro[..2]);
    append_with_limit(&output, &euro[2..]);

    let output = output.lock().unwrap();
    assert_eq!(String::from_utf8_lossy(&output.output), "€");
    assert!(!output.truncated);
}

#[test]
fn append_with_limit_truncates_by_bytes() {
    let output = Mutex::new(TerminalOutputState {
        output: Vec::new(),
        truncated: false,
        output_limit: 4,
    });

    append_with_limit(&output, b"abcdef");

    let output = output.lock().unwrap();
    assert_eq!(output.output, b"cdef");
    assert!(output.truncated);
}

#[test]
fn terminal_slot_race_reserves_cap_under_concurrency() {
    let manager = Arc::new(TerminalManager::new(2));
    let barrier = Arc::new(Barrier::new(8));

    let handles = (0..8)
        .map(|_| {
            let manager = Arc::clone(&manager);
            let barrier = Arc::clone(&barrier);
            thread::spawn(move || {
                barrier.wait();
                manager.reserve_slot()
            })
        })
        .collect::<Vec<_>>();

    let mut allowed = 0;
    let mut denied = 0;
    let mut reserved_ids = Vec::new();
    for handle in handles {
        match handle.join().expect("reservation thread") {
            Ok(terminal_id) => {
                allowed += 1;
                reserved_ids.push(terminal_id);
            }
            Err(error) if error.code == TERMINAL_DENIED => denied += 1,
            Err(error) => panic!("unexpected reservation error: {error}"),
        }
    }

    assert_eq!(allowed, 2);
    assert_eq!(denied, 6);
    assert_eq!(manager.terminals.lock().unwrap().len(), 2);
    assert_eq!(reserved_ids.len(), 2);
}

#[test]
#[cfg(unix)]
fn terminal_output_enforces_wall_clock_limit() {
    let manager = TerminalManager::new_with_limits(1, Duration::from_millis(1));
    let create = CreateTerminalRequest::new("session-1", "sh")
        .args(vec!["-c".to_string(), "sleep 2".to_string()]);
    let terminal_id = manager
        .handle_create(&create, &DeniedBinaries::new(BTreeSet::new()))
        .expect("terminal starts")
        .terminal_id;

    thread::sleep(Duration::from_millis(20));

    let output = TerminalOutputRequest::new("session-1", terminal_id);
    let error = manager
        .handle_output(&output)
        .expect_err("expired terminal should be denied");
    assert_eq!(error.code, TERMINAL_DENIED);
    assert!(error.message.contains("wall-clock"));
}

#[test]
fn wait_for_output_drain_requires_generation_quiescence_or_reader_close() {
    let output = Arc::new(Mutex::new(TerminalOutputState {
        output: b"tail".to_vec(),
        truncated: true,
        output_limit: 4,
    }));
    let signal = Arc::new(TerminalWaitSignal::new());
    signal.note_output_updated();

    let writer_output = Arc::clone(&output);
    let writer_signal = Arc::clone(&signal);
    let writer = thread::spawn(move || {
        thread::sleep(Duration::from_millis(20));
        append_with_limit(&writer_output, b"more");
        writer_signal.note_output_updated();
        thread::sleep(Duration::from_millis(20));
        writer_signal.note_reader_closed();
    });

    let start = Instant::now();
    wait_for_output_drain(&signal, Duration::from_millis(100));
    writer.join().expect("writer thread");

    assert!(
        start.elapsed() >= Duration::from_millis(30),
        "drain should wait through at least one signal transition"
    );
    let output = output.lock().unwrap();
    assert_eq!(output.output, b"more");
}

#[test]
fn wait_for_exit_or_error_is_level_triggered_after_pre_wait_exit() {
    let signal = Arc::new(TerminalWaitSignal::new());
    let expected = TerminalExitStatus::new().exit_code(Some(0));
    signal.finish_exit(expected.clone());

    let start = Instant::now();
    let outcome = signal.wait_for_exit_or_error(Duration::from_secs(1));

    assert!(
        start.elapsed() < Duration::from_millis(100),
        "pre-published exit should not wait for the timeout"
    );
    match outcome {
        TerminalLifecycleWait::Exit(exit_status) => assert_eq!(exit_status, expected),
        TerminalLifecycleWait::LifecycleError(error) => {
            panic!("expected exit status, got lifecycle error: {error}");
        }
        TerminalLifecycleWait::TimedOut => panic!("expected exit status, got timeout"),
    }
}

#[test]
#[cfg(unix)]
fn terminal_wait_on_same_terminal_does_not_block_output_or_kill() {
    let manager = Arc::new(TerminalManager::new(1));
    let terminal_id = manager
        .handle_create(
            &CreateTerminalRequest::new("session-1", "sh")
                .args(vec!["-c".to_string(), "printf ready; sleep 5".to_string()]),
            &DeniedBinaries::new(BTreeSet::new()),
        )
        .expect("terminal starts")
        .terminal_id;

    let wait_manager = Arc::clone(&manager);
    let wait_terminal = terminal_id.clone();
    let wait_thread = thread::spawn(move || {
        wait_manager
            .handle_wait_for_exit(&WaitForTerminalExitRequest::new("session-1", wait_terminal))
    });

    thread::sleep(Duration::from_millis(100));

    let output_started = Instant::now();
    let output = manager
        .handle_output(&TerminalOutputRequest::new(
            "session-1",
            terminal_id.clone(),
        ))
        .expect("terminal output");
    assert!(
        output_started.elapsed() < Duration::from_secs(1),
        "same-terminal wait must not block output"
    );
    assert!(output.output.contains("ready"), "{output:?}");

    let kill_started = Instant::now();
    manager
        .handle_kill(&KillTerminalRequest::new("session-1", terminal_id.clone()))
        .expect("kill terminal");
    assert!(
        kill_started.elapsed() < Duration::from_secs(1),
        "same-terminal wait must not block kill"
    );

    wait_thread
        .join()
        .expect("wait thread")
        .expect("wait terminal");
    manager
        .handle_release(&agent_client_protocol::schema::ReleaseTerminalRequest::new(
            "session-1",
            terminal_id,
        ))
        .expect("release terminal");
}
