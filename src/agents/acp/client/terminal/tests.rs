use std::collections::BTreeSet;
use std::sync::{Arc, Barrier, Mutex};
use std::thread;
use std::time::Duration;

use agent_client_protocol::schema::{CreateTerminalRequest, TerminalOutputRequest};

use super::output::append_with_limit;
use super::{TerminalManager, TerminalOutputState};
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
fn terminal_slot_reservation_enforces_cap_under_concurrency() {
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
    for handle in handles {
        match handle.join().expect("reservation thread") {
            Ok(()) => allowed += 1,
            Err(error) if error.code == TERMINAL_DENIED => denied += 1,
            Err(error) => panic!("unexpected reservation error: {error}"),
        }
    }

    assert_eq!(allowed, 2);
    assert_eq!(denied, 6);
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
