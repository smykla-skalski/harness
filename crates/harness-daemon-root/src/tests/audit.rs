use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::sync::{Arc, Barrier};

use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use super::super::{
    append_event, auth_token_path, diagnostics, ensure_auth_token, events_path, read_recent_events,
};

#[test]
fn ensure_auth_token_writes_strict_permissions() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let token = ensure_auth_token().expect("token");
        assert!(!token.is_empty());
        let metadata = fs::metadata(auth_token_path()).expect("metadata");
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    });
}

#[test]
fn diagnostics_include_latest_event_and_database_path() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        append_event("info", "daemon booted").expect("append event");

        let diagnostics = diagnostics().expect("diagnostics");
        assert!(diagnostics.auth_token_path.ends_with("auth-token"));
        assert!(diagnostics.database_path.ends_with("harness.db"));
        assert_eq!(diagnostics.database_size_bytes, 0);
        assert_eq!(
            diagnostics.last_event.expect("latest event").message,
            "daemon booted"
        );
    });
}

#[test]
fn read_recent_events_returns_last_entries_in_order() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        append_event("info", "daemon booted").expect("append event");
        append_event("warn", "stalled session").expect("append event");
        append_event("info", "refresh complete").expect("append event");

        let events = read_recent_events(2).expect("recent events");

        assert_eq!(events.len(), 2);
        assert_eq!(events[0].message, "stalled session");
        assert_eq!(events[1].message, "refresh complete");
    });
}

#[test]
fn read_recent_events_recovers_concatenated_entries() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        append_event("info", "older event").expect("append older event");
        let path = events_path();
        let mut content = fs::read_to_string(&path).expect("read events");
        content.truncate(content.trim_end().len());
        content.push_str(
            r#"{"recorded_at":"2026-08-08T06:06:27Z","level":"info","message":"newer event"}"#,
        );
        content.push('\n');
        fs::write(path, content).expect("write concatenated events");

        let events = read_recent_events(2).expect("recover concatenated events");

        assert_eq!(events.len(), 2);
        assert_eq!(events[0].message, "older event");
        assert_eq!(events[1].message, "newer event");
    });
}

#[test]
fn concurrent_appends_keep_one_event_per_line() {
    const WRITERS: usize = 8;
    const EVENTS_PER_WRITER: usize = 32;

    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let barrier = Arc::new(Barrier::new(WRITERS));
        let writers = (0..WRITERS)
            .map(|writer| {
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    barrier.wait();
                    for event in 0..EVENTS_PER_WRITER {
                        append_event("info", &format!("writer {writer} event {event}"))
                            .expect("append event");
                    }
                })
            })
            .collect::<Vec<_>>();

        for writer in writers {
            writer.join().expect("join writer");
        }

        let content = fs::read_to_string(events_path()).expect("read events");
        let lines = content.lines().collect::<Vec<_>>();
        assert_eq!(lines.len(), WRITERS * EVENTS_PER_WRITER);
        for line in lines {
            serde_json::from_str::<serde_json::Value>(line).expect("parse complete event line");
        }
    });
}
