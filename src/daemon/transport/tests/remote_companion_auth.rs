use clap::{CommandFactory, Parser};
use harness_testkit::with_isolated_harness_env;

use crate::daemon::db::DaemonDb;
use crate::daemon::remote::RemoteDaemonServeConfig;
use crate::daemon::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeRenewalIssuer, RemoteAcmeRenewalRequest,
    RemoteCertificateBundle,
};

use super::super::DaemonRemoteServeArgs;
use super::super::remote_serve::execute_remote_serve_with_issuer;

#[derive(Debug, Parser)]
struct DaemonRemoteServeArgsTestHarness {
    #[command(flatten)]
    args: DaemonRemoteServeArgs,
}

fn parse(extra: &[&str]) -> DaemonRemoteServeArgs {
    let mut arguments = vec![
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ];
    arguments.extend_from_slice(extra);
    DaemonRemoteServeArgsTestHarness::try_parse_from(arguments)
        .expect("parse remote serve args")
        .args
}

#[test]
fn companion_upstream_requires_an_auth_token_file() {
    let args = parse(&[
        "--companion-upstream",
        "http://127.0.0.1:8787",
        "--companion-systemd-socket-activated",
    ]);

    let error = args
        .remote_auth_scaffold_config()
        .expect_err("an unauthenticated companion hop must be rejected");

    assert!(
        error
            .to_string()
            .contains("--companion-auth-token-file is required")
    );
}

#[test]
fn manual_companion_configuration_requires_socket_activation() {
    let args = parse(&[
        "--companion-upstream",
        "http://127.0.0.1:8787",
        "--companion-auth-token-file",
        "/tmp/unused-companion-token",
    ]);

    let error = args
        .remote_auth_scaffold_config()
        .expect_err("manual companion startup must be rejected");

    assert!(
        error
            .to_string()
            .contains("supported only through the harness-systemd socket-activated deployment")
    );
    assert!(
        !error
            .to_string()
            .contains("--companion-systemd-socket-activated")
    );
}

#[test]
fn socket_activation_marker_requires_a_companion_upstream() {
    let args = parse(&["--companion-systemd-socket-activated"]);

    let error = args
        .remote_auth_scaffold_config()
        .expect_err("an orphaned internal marker must be rejected");

    assert!(
        error
            .to_string()
            .contains("internal companion socket-activation marker requires --companion-upstream")
    );
}

#[test]
fn internal_companion_arguments_are_hidden_from_cli_help() {
    let help = DaemonRemoteServeArgsTestHarness::command()
        .render_long_help()
        .to_string();

    for argument in [
        "companion-upstream",
        "companion-auth-token-file",
        "companion-systemd-socket-activated",
        "companion-path-prefix",
    ] {
        assert!(!help.contains(argument), "{argument} must stay internal");
    }
}

#[test]
fn companion_auth_token_file_requires_an_upstream() {
    let args = parse(&["--companion-auth-token-file", "/tmp/unused-companion-token"]);

    let error = args
        .remote_auth_scaffold_config()
        .expect_err("a credential without a companion must be rejected");

    assert!(
        error
            .to_string()
            .contains("--companion-auth-token-file requires --companion-upstream")
    );
}

#[test]
fn companion_auth_is_validated_before_remote_serve_state_changes() {
    let temp = tempfile::tempdir().expect("temp dir");
    with_isolated_harness_env(temp.path(), || {
        let db_path = temp.path().join("harness.db");
        let args = parse(&[
            "--companion-upstream",
            "http://127.0.0.1:8787",
            "--companion-systemd-socket-activated",
        ]);

        let error = execute_remote_serve_with_issuer(
            &args,
            || DaemonDb::open(&db_path),
            |_| panic!("invalid companion auth must prevent the HTTPS runner"),
            &PanicIssuer,
            "2026-07-26T12:00:00Z",
        )
        .expect_err("invalid companion auth must stop remote startup");

        assert!(
            error
                .to_string()
                .contains("--companion-auth-token-file is required")
        );
        let db = DaemonDb::open(&db_path).expect("reopen db");
        let state = db.load_remote_acme_state().expect("load ACME state");
        assert!(state.serve_config.is_none());
        assert!(!state.account_configured);
        assert!(!state.certificate_configured);
    });
}

#[cfg(unix)]
#[test]
fn companion_auth_token_file_must_not_be_group_or_world_accessible() {
    use std::os::unix::fs::PermissionsExt as _;

    let temp = tempfile::tempdir().expect("temp dir");
    let path = temp.path().join("companion-token");
    std::fs::write(&path, "private-daemon-panel-token-0123456789").expect("write token");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644))
        .expect("make token public");
    let args = parse(&[
        "--companion-upstream",
        "http://127.0.0.1:8787",
        "--companion-auth-token-file",
        path.to_str().expect("UTF-8 token path"),
        "--companion-systemd-socket-activated",
    ]);

    let error = args
        .remote_auth_scaffold_config()
        .expect_err("public token file must be rejected");

    assert!(error.to_string().contains("accessible by group or others"));
}

#[cfg(unix)]
#[test]
fn private_companion_token_builds_a_redacted_authenticated_route() {
    use std::os::unix::fs::PermissionsExt as _;

    let temp = tempfile::tempdir().expect("temp dir");
    let path = temp.path().join("companion-token");
    let secret = "private-daemon-panel-token-0123456789";
    std::fs::write(&path, format!("{secret}\n")).expect("write token");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
        .expect("make token private");
    let args = parse(&[
        "--companion-upstream",
        "http://127.0.0.1:8787",
        "--companion-auth-token-file",
        path.to_str().expect("UTF-8 token path"),
        "--companion-systemd-socket-activated",
        "--companion-path-prefix",
        "/dashboard",
    ]);

    let config = args
        .remote_auth_scaffold_config()
        .expect("authenticated companion config");
    let route = config.companion.expect("companion route");
    let debug = format!("{route:?}");

    assert_eq!(route.upstream_origin(), "http://127.0.0.1:8787");
    assert_eq!(route.path_prefix(), "/dashboard");
    assert!(debug.contains("REDACTED"));
    assert!(!debug.contains(secret));
}

struct PanicIssuer;

impl RemoteAcmeRenewalIssuer for PanicIssuer {
    fn create_account(
        &self,
        _config: &RemoteDaemonServeConfig,
    ) -> Result<RemoteAcmeAccountCredentials, String> {
        panic!("invalid companion auth must prevent ACME account creation")
    }

    fn renew_certificate(
        &self,
        _request: &RemoteAcmeRenewalRequest,
    ) -> Result<RemoteCertificateBundle, String> {
        panic!("invalid companion auth must prevent ACME certificate issuance")
    }
}
