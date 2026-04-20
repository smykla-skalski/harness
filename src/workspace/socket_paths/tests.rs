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
    let home: PathBuf = "/Users/verylonguser@corp.example.com".into();
    let root = home
        .join("Library")
        .join("Group Containers")
        .join("Q498EB36N4.io.harnessmonitor")
        .join("sock");
    let path = session_socket(&root, "abc12345", "mcp-registry");
    let bytes = path.to_string_lossy().as_bytes().len();
    assert!(bytes < 104, "socket path {} is {} bytes", path.display(), bytes);
}

#[test]
fn purpose_rejects_slash() {
    assert!(validate_purpose("mcp-registry").is_ok());
    assert!(validate_purpose("has/slash").is_err());
    assert!(validate_purpose("").is_err());
}
