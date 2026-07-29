use std::fs;
use std::net::SocketAddr;

use super::{
    SybraGatewayConfig, SybraGatewayConfigError, SybraOperation, SybraOwner,
    SybraOwnershipRegistry, SybraUpstreamToken,
};

const TOKEN: &str = "sybra-private-upstream-token-0123456789";

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
    let token = super::SybraBrowserToken::new(TOKEN.to_owned());
    let debug = format!("{token:?}");
    assert!(debug.contains("REDACTED"));
    assert!(!debug.contains(TOKEN));
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
    assert_eq!(config.upstream_token(), TOKEN);

    let browser = super::SybraBrowserToken::from_private_file(&path).expect("browser token");
    assert!(format!("{browser:?}").contains("REDACTED"));
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
