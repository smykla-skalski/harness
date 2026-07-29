use std::fs;
use std::net::SocketAddr;

use super::{
    SybraGatewayConfig, SybraGatewayConfigError, SybraOperation, SybraOwner,
    SybraOwnershipRegistry, SybraUpstreamToken,
};

const TOKEN: &str = "sybra-private-upstream-token-0123456789";
const BROWSER_TOKEN: &str = "sybra-browser-edge-token-9876543210";

fn config(origin: &str) -> SybraGatewayConfig {
    SybraGatewayConfig::new(origin, SybraUpstreamToken::parse(TOKEN).expect("token"))
        .expect("config")
}

#[test]
fn numeric_loopback_origin_and_explicit_port_are_required() {
    for origin in [
        "https://127.0.0.1:8080",
        "http://localhost:8080",
        "http://192.0.2.1:8080",
        "http://127.0.0.1",
        "http://user@127.0.0.1:8080",
        "http://127.0.0.1:8080/path",
        "http://127.0.0.1:8080?query=bad",
    ] {
        assert!(
            SybraGatewayConfig::new(origin, SybraUpstreamToken::parse(TOKEN).expect("token"))
                .is_err(),
            "{origin}"
        );
    }
}

#[test]
fn listener_loop_is_terminal() {
    let config = config("http://127.0.0.1:8080");
    let listener: SocketAddr = "127.0.0.1:8080".parse().expect("address");

    assert_eq!(
        config.reject_listener_loop(listener),
        Err(SybraGatewayConfigError::UpstreamLoop(listener))
    );
}

#[test]
fn config_debug_redacts_token() {
    let config = config("http://127.0.0.1:8080");
    let debug = format!("{config:?}");
    assert!(debug.contains("REDACTED"));
    assert!(!debug.contains(TOKEN));
}

#[test]
fn browser_token_debug_and_comparison_do_not_disclose_secret() {
    let token = super::SybraBrowserToken::new(BROWSER_TOKEN.to_owned());
    let debug = format!("{token:?}");
    assert!(debug.contains("REDACTED"));
    assert!(!debug.contains(BROWSER_TOKEN));
}

#[cfg(unix)]
#[test]
fn private_token_file_is_loaded_during_configuration() {
    use std::os::unix::fs::PermissionsExt as _;

    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("token");
    fs::write(&path, TOKEN).expect("write");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("permissions");

    let config = SybraGatewayConfig::from_private_token_file("http://127.0.0.1:8080", &path)
        .expect("config");
    assert_eq!(config.token.secret(), TOKEN);

    fs::write(&path, BROWSER_TOKEN).expect("write browser token");
    let browser = super::SybraBrowserToken::from_private_file(&path).expect("browser token");
    assert!(format!("{browser:?}").contains("REDACTED"));
}

#[test]
fn equal_browser_and_upstream_credentials_are_rejected_without_disclosure() {
    let config = config("http://127.0.0.1:8080");
    let browser = super::SybraBrowserToken::new(TOKEN.to_owned());
    let error = config
        .reject_matching_browser_token(&browser)
        .expect_err("equal credentials rejected");

    assert_eq!(error, SybraGatewayConfigError::TokenCollision);
    assert!(!error.to_string().contains(TOKEN));
}

#[cfg(unix)]
#[test]
fn credential_file_rejects_open_permissions_and_non_regular_paths() {
    use std::os::unix::fs::PermissionsExt as _;

    let directory = tempfile::tempdir().expect("directory");
    for (name, mode) in [("group-readable", 0o640), ("other-readable", 0o604)] {
        let path = directory.path().join(name);
        fs::write(&path, TOKEN).expect("write token");
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).expect("permissions");
        assert!(matches!(
            super::SybraBrowserToken::from_private_file(&path),
            Err(SybraGatewayConfigError::TokenPermissionsTooOpen(_))
        ));
    }
    assert!(matches!(
        super::SybraBrowserToken::from_private_file(directory.path()),
        Err(SybraGatewayConfigError::TokenNotRegularFile(_))
    ));
}

#[cfg(unix)]
#[test]
fn credential_file_does_not_follow_symlinks() {
    use std::os::unix::fs::{PermissionsExt as _, symlink};

    let directory = tempfile::tempdir().expect("directory");
    let target = directory.path().join("target");
    let link = directory.path().join("link");
    fs::write(&target, TOKEN).expect("write target");
    fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).expect("permissions");
    symlink(&target, &link).expect("symlink");

    assert!(matches!(
        super::SybraBrowserToken::from_private_file(&link),
        Err(SybraGatewayConfigError::TokenUnreadable(_))
    ));
}

#[cfg(unix)]
#[test]
fn credential_file_rejects_short_invalid_and_oversized_values_without_disclosure() {
    use std::os::unix::fs::PermissionsExt as _;

    let directory = tempfile::tempdir().expect("directory");
    let cases = [
        (
            "short",
            "too-short".to_owned(),
            SybraGatewayConfigError::TokenTooShort,
        ),
        (
            "invalid",
            format!("{TOKEN}\ninvalid"),
            SybraGatewayConfigError::TokenInvalidCharacter,
        ),
    ];
    for (name, value, expected) in cases {
        let path = directory.path().join(name);
        fs::write(&path, &value).expect("write credential");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("permissions");
        let error =
            super::SybraBrowserToken::from_private_file(&path).expect_err("credential rejected");
        assert_eq!(error, expected);
        assert!(!error.to_string().contains(&value));
    }

    let oversized = "x".repeat(64 * 1024 + 1);
    let path = directory.path().join("oversized");
    fs::write(&path, &oversized).expect("write oversized credential");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("permissions");
    let error = super::SybraBrowserToken::from_private_file(&path)
        .expect_err("oversized credential rejected");
    assert!(matches!(error, SybraGatewayConfigError::TokenUnreadable(_)));
    assert!(!error.to_string().contains(&oversized));
}

#[test]
fn ownership_snapshot_defaults_upstream_and_terminal_overrides_win() {
    let rpc = SybraOperation::Rpc {
        service: "TaskService".to_owned(),
        method: "Create".to_owned(),
    };
    let native =
        SybraOwnershipRegistry::default_upstream().with_owner(rpc.clone(), SybraOwner::Native);
    let unsupported =
        SybraOwnershipRegistry::default_upstream().with_owner(rpc.clone(), SybraOwner::Unsupported);

    assert_eq!(
        SybraOwnershipRegistry::default_upstream().owner(&rpc),
        SybraOwner::Upstream
    );
    assert_eq!(native.owner(&rpc), SybraOwner::Native);
    assert_eq!(unsupported.owner(&rpc), SybraOwner::Unsupported);
}
