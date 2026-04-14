use std::fs;
use std::os::unix::fs::PermissionsExt;

use tempfile::tempdir;

use super::super::{
    append_event, auth_token_path, diagnostics, ensure_auth_token, read_recent_events,
};

#[test]
fn ensure_auth_token_writes_strict_permissions() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path")))],
        || {
            let token = ensure_auth_token().expect("token");
            assert!(!token.is_empty());
            let metadata = fs::metadata(auth_token_path()).expect("metadata");
            assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        },
    );
}

#[test]
fn diagnostics_include_latest_event_and_database_path() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path")))],
        || {
            append_event("info", "daemon booted").expect("append event");

            let diagnostics = diagnostics().expect("diagnostics");
            assert!(diagnostics.auth_token_path.ends_with("auth-token"));
            assert!(diagnostics.database_path.ends_with("harness.db"));
            assert_eq!(diagnostics.database_size_bytes, 0);
            assert_eq!(
                diagnostics.last_event.expect("latest event").message,
                "daemon booted"
            );
        },
    );
}

#[test]
fn read_recent_events_returns_last_entries_in_order() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path")))],
        || {
            append_event("info", "daemon booted").expect("append event");
            append_event("warn", "stalled session").expect("append event");
            append_event("info", "refresh complete").expect("append event");

            let events = read_recent_events(2).expect("recent events");

            assert_eq!(events.len(), 2);
            assert_eq!(events[0].message, "stalled session");
            assert_eq!(events[1].message, "refresh complete");
        },
    );
}
