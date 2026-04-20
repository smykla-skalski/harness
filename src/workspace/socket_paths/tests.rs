use std::path::PathBuf;

use super::*;

#[test]
fn session_socket_path_layout() {
    let root = PathBuf::from("/g/sock");
    let path = session_socket(&root, "abc12345", "agent");
    assert_eq!(path, PathBuf::from("/g/sock/abc12345-agent.sock"));
}

#[test]
fn path_fits_sun_path_limit_with_long_home() {
    // Budget guardrail: synthesize a realistic home plus the group-container
    // prefix that sub-project A ships, and verify the longest purpose
    // currently in use still fits under 104 bytes. Pathological usernames
    // (18+ chars) push the budget over; the intent of this test, per the
    // design doc, is to fail early in that case so either the purpose is
    // shortened or the socket root relocated.
    let home: PathBuf = "/Users/bart.dev".into();
    let root = home
        .join("Library")
        .join("Group Containers")
        .join("Q498EB36N4.io.harnessmonitor")
        .join("sock");
    let path = session_socket(&root, "abc12345", "mcp-registry");
    let bytes = path.to_string_lossy().as_bytes().len();
    assert!(
        bytes < 104,
        "socket path {} is {} bytes",
        path.display(),
        bytes,
    );
}

#[test]
fn purpose_rejects_slash() {
    assert!(validate_purpose("mcp-registry").is_ok());
    assert!(validate_purpose("has/slash").is_err());
    assert!(validate_purpose("").is_err());
}
