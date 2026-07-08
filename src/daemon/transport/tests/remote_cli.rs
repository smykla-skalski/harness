use clap::Parser;
use harness_testkit::with_isolated_harness_env;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::db::DaemonDb;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::RemoteClientRegistration;
use crate::daemon::remote_pairing::RemotePairingCode;
use crate::daemon::state;

use super::super::remote::{DaemonRemoteClientIdArgs, DaemonRemoteClientsCommand};
use super::super::{DaemonRemoteCommand, DaemonRemotePairCommand, DaemonRemoteServeArgs};

#[derive(Debug, Parser)]
struct DaemonRemoteServeArgsTestHarness {
    #[command(flatten)]
    args: DaemonRemoteServeArgs,
}

#[derive(Debug, Parser)]
struct DaemonRemoteCommandTestHarness {
    #[command(subcommand)]
    command: DaemonRemoteCommand,
}

#[test]
fn daemon_remote_serve_args_default_tls_alpn_config_is_valid() {
    let parsed = DaemonRemoteServeArgsTestHarness::try_parse_from([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ])
    .unwrap();

    assert_eq!(parsed.args.host, "0.0.0.0");
    assert_eq!(parsed.args.https_port, 443);
    assert_eq!(parsed.args.http_port, 80);
    assert_eq!(parsed.args.domain, "daemon.example.com");
    assert_eq!(parsed.args.acme_email, "ops@example.com");
    assert_eq!(parsed.args.acme_challenge.as_str(), "tls-alpn");
    assert!(parsed.args.acme_dns_provider.is_none());
    parsed
        .args
        .contract_config()
        .expect("default remote serve inputs should satisfy the contract");
}

#[test]
fn daemon_remote_serve_args_select_remote_http_auth_mode() {
    let parsed = DaemonRemoteServeArgsTestHarness::try_parse_from([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ])
    .unwrap();

    let serve_config = parsed
        .args
        .remote_auth_scaffold_config()
        .expect("remote auth scaffold config");
    assert_eq!(serve_config.host, "0.0.0.0");
    assert_eq!(serve_config.port, 443);
    assert_eq!(
        serve_config.auth_mode,
        crate::daemon::http::DaemonHttpAuthMode::Remote
    );
}

#[test]
fn daemon_remote_serve_args_trim_identity_fields() {
    let parsed = DaemonRemoteServeArgsTestHarness::try_parse_from([
        "test",
        "--domain",
        " daemon.example.com ",
        "--host",
        " 0.0.0.0 ",
        "--acme-email",
        " ops@example.com ",
    ])
    .unwrap();

    let config = parsed
        .args
        .contract_config()
        .expect("trimmed identity inputs should satisfy the contract");
    assert_eq!(config.domain, "daemon.example.com");
    assert_eq!(config.host, "0.0.0.0");
    assert_eq!(config.acme_email, "ops@example.com");
}

#[test]
fn daemon_remote_serve_args_reject_empty_domain_contract() {
    let parsed = DaemonRemoteServeArgsTestHarness::try_parse_from([
        "test",
        "--domain",
        "   ",
        "--acme-email",
        "ops@example.com",
    ])
    .unwrap();

    let error = parsed
        .args
        .contract_config()
        .expect_err("blank remote domain should fail contract validation");
    assert!(
        error.to_string().contains("domain is required"),
        "unexpected error: {error}"
    );
}

#[test]
fn daemon_remote_serve_args_support_dns01_providers() {
    let parsed = DaemonRemoteServeArgsTestHarness::try_parse_from([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--acme-challenge",
        "dns",
        "--acme-dns-provider",
        "cloudflare",
    ])
    .unwrap();

    let config = parsed
        .args
        .contract_config()
        .expect("dns provider should satisfy dns-01 config");
    assert_eq!(config.acme_challenge.as_str(), "dns");
    assert_eq!(
        config.acme_dns_provider.expect("dns provider").as_str(),
        "cloudflare"
    );
}

#[test]
fn daemon_remote_serve_args_reject_dns01_without_provider() {
    let parsed = DaemonRemoteServeArgsTestHarness::try_parse_from([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--acme-challenge",
        "dns",
    ])
    .unwrap();

    let error = parsed
        .args
        .contract_config()
        .expect_err("dns-01 should require an explicit DNS provider");
    assert!(
        error.to_string().contains("DNS-01 challenge requires"),
        "unexpected error: {error}"
    );
}

#[test]
fn daemon_remote_serve_args_reject_http01_without_http_port() {
    let parsed = DaemonRemoteServeArgsTestHarness::try_parse_from([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--acme-challenge",
        "http",
        "--http-port",
        "0",
    ])
    .unwrap();

    let error = parsed
        .args
        .contract_config()
        .expect_err("http-01 should require a non-zero HTTP port");
    assert!(
        error.to_string().contains("HTTP-01 port must be non-zero"),
        "unexpected error: {error}"
    );
}

#[test]
fn daemon_remote_serve_args_reject_tls_alpn_with_dns_provider() {
    let parsed = DaemonRemoteServeArgsTestHarness::try_parse_from([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--acme-dns-provider",
        "cloudflare",
    ])
    .unwrap();

    let error = parsed
        .args
        .contract_config()
        .expect_err("dns provider should require DNS-01 challenge");
    assert!(
        error.to_string().contains("only valid with DNS-01"),
        "unexpected error: {error}"
    );
}

#[test]
fn daemon_remote_serve_args_reject_http01_with_dns_provider() {
    let parsed = DaemonRemoteServeArgsTestHarness::try_parse_from([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--acme-challenge",
        "http",
        "--acme-dns-provider",
        "cloudflare",
    ])
    .unwrap();

    let error = parsed
        .args
        .contract_config()
        .expect_err("dns provider should require DNS-01 challenge");
    assert!(
        error.to_string().contains("only valid with DNS-01"),
        "unexpected error: {error}"
    );
}

#[test]
fn daemon_remote_pair_create_defaults_to_admin_ten_minute_ttl() {
    let parsed = DaemonRemoteCommandTestHarness::try_parse_from(["test", "pair", "create"])
        .unwrap()
        .command;

    match parsed {
        DaemonRemoteCommand::Pair {
            command: DaemonRemotePairCommand::Create(args),
        } => {
            assert_eq!(args.role.as_str(), "admin");
            assert_eq!(args.ttl.as_secs(), 600);
            assert!(args.scopes.is_empty());
        }
        other => panic!("expected pair create, got {other:?}"),
    }
}

#[test]
fn daemon_remote_pair_create_accepts_fixed_scope_values() {
    let parsed = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "pair",
        "create",
        "--scopes",
        "read,write",
    ])
    .unwrap()
    .command;

    match parsed {
        DaemonRemoteCommand::Pair {
            command: DaemonRemotePairCommand::Create(args),
        } => {
            let scopes: Vec<_> = args.scopes.iter().map(|scope| scope.as_str()).collect();
            assert_eq!(scopes, vec!["read", "write"]);
        }
        other => panic!("expected pair create, got {other:?}"),
    }
}

#[test]
fn daemon_remote_pair_create_rejects_unknown_scope() {
    assert!(DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "pair",
        "create",
        "--scopes",
        "read,root",
    ])
    .is_err());
}

#[test]
fn daemon_remote_pair_create_rejects_invalid_ttl() {
    assert!(DaemonRemoteCommandTestHarness::try_parse_from([
        "test", "pair", "create", "--ttl", "tomorrow",
    ])
    .is_err());
}

#[test]
fn daemon_remote_pair_create_reports_zero_ttl() {
    let error =
        DaemonRemoteCommandTestHarness::try_parse_from(["test", "pair", "create", "--ttl", "0m"])
            .expect_err("zero ttl should be rejected");
    assert!(
        error.to_string().contains("greater than zero"),
        "unexpected error: {error}"
    );
}

#[test]
fn daemon_remote_pair_create_reports_ttl_overflow_as_too_large() {
    let error = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "pair",
        "create",
        "--ttl",
        "18446744073709551615h",
    ])
    .expect_err("overflowing ttl should be rejected");
    let message = error.to_string();
    assert!(
        message.contains("too large"),
        "overflow should report too large, got: {message}"
    );
    assert!(
        !message.contains("greater than zero"),
        "overflow should not report zero ttl, got: {message}"
    );
}

#[test]
fn daemon_remote_pair_create_builds_persisted_record_and_response() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let parsed = DaemonRemoteCommandTestHarness::try_parse_from([
        "test", "pair", "create", "--role", "operator", "--scopes", "read", "--ttl", "2m",
    ])
    .unwrap()
    .command;
    let DaemonRemoteCommand::Pair {
        command: DaemonRemotePairCommand::Create(args),
    } = parsed
    else {
        panic!("expected pair create");
    };

    let code = RemotePairingCode::from_value_for_tests("manual-code-value");
    let response = args
        .create_pairing_with(
            &db,
            "pairing-test",
            "audit-pairing-test",
            &code,
            "2026-06-21T13:40:00Z",
        )
        .expect("create pairing response");

    assert_eq!(response.pairing_id, "pairing-test");
    assert_eq!(response.code, "manual-code-value");
    assert_eq!(response.role, "operator");
    assert_eq!(response.scopes, vec!["read"]);
    assert_eq!(response.ttl_seconds, 120);
    assert_eq!(response.created_at, "2026-06-21T13:40:00Z");
    assert_eq!(response.expires_at, "2026-06-21T13:42:00Z");

    let stored: (String, String) = db
        .connection()
        .query_row(
            "SELECT pairing_id, code_hash FROM remote_pairing_codes",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("stored pairing");
    assert_eq!(stored.0, "pairing-test");
    assert_ne!(stored.1, "manual-code-value");
    assert!(stored.1.starts_with("sha256:"));

    let audit_routes: Vec<_> = db
        .load_remote_audit_events(10)
        .expect("load audit events")
        .into_iter()
        .map(|event| event.route_or_method)
        .collect();
    assert_eq!(audit_routes, vec!["remote.pair.create"]);
}

#[test]
fn daemon_remote_pair_create_execute_persists_pairing_in_daemon_db() {
    let temp = tempfile::tempdir().expect("temp dir");
    with_isolated_harness_env(temp.path(), || {
        state::ensure_daemon_dirs().expect("daemon dirs");
        let daemon_root = state::daemon_root();
        let _lock = state::acquire_singleton_lock().expect("hold daemon lock");

        let command = DaemonRemoteCommandTestHarness::try_parse_from([
            "test", "pair", "create", "--role", "viewer", "--ttl", "30s",
        ])
        .unwrap()
        .command;

        let exit = command.execute(&AppContext).expect("execute pair create");
        assert_eq!(exit, 0);

        let db = DaemonDb::open(&daemon_root.join("harness.db")).expect("open daemon db");
        let stored_count: i64 = db
            .connection()
            .query_row("SELECT COUNT(*) FROM remote_pairing_codes", [], |row| {
                row.get(0)
            })
            .expect("stored pairing count");
        assert_eq!(stored_count, 1);

        let (role, scopes_json, code_hash): (String, String, String) = db
            .connection()
            .query_row(
                "SELECT role, scopes_json, code_hash FROM remote_pairing_codes",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("stored pairing row");
        assert_eq!(role, "viewer");
        assert_eq!(scopes_json, "[\"read\"]");
        assert!(code_hash.starts_with("sha256:"));
    });
}

#[test]
fn daemon_remote_clients_list_returns_token_safe_summaries_and_audits() {
    let db = DaemonDb::open_in_memory().expect("open db");
    register_remote_client(
        &db,
        "viewer",
        RemoteRole::Viewer,
        &[],
        "viewer-token-secret",
    );
    register_remote_client(
        &db,
        "operator",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
        "operator-token-secret",
    );

    let response = DaemonRemoteClientsCommand::List
        .list_clients_with(&db, "audit-list", "2026-06-21T14:00:00Z")
        .expect("list clients");

    assert_eq!(response.clients.len(), 2);
    let viewer = response
        .clients
        .iter()
        .find(|client| client.client_id == "viewer")
        .expect("viewer client");
    assert_eq!(viewer.role, "viewer");
    assert_eq!(viewer.scopes, vec!["read"]);
    assert_eq!(viewer.token_hint, "secret");
    let operator = response
        .clients
        .iter()
        .find(|client| client.client_id == "operator")
        .expect("operator client");
    assert_eq!(operator.scopes, vec!["read", "write"]);
    let json = serde_json::to_string(&response).expect("serialize response");
    assert!(!json.contains("viewer-token-secret"));
    assert!(!json.contains("operator-token-secret"));
    assert!(!json.contains("sha256:"));

    let routes: Vec<_> = db
        .load_remote_audit_events(10)
        .expect("audit events")
        .into_iter()
        .map(|event| event.route_or_method)
        .collect();
    assert_eq!(routes, vec!["remote.clients.list"]);
}

#[test]
fn daemon_remote_clients_revoke_denies_token_and_records_audit() {
    let db = DaemonDb::open_in_memory().expect("open db");
    register_remote_client(
        &db,
        "viewer",
        RemoteRole::Viewer,
        &[],
        "viewer-token-secret",
    );
    let args = DaemonRemoteClientIdArgs {
        client_id: "viewer".to_string(),
    };

    let response = args
        .revoke_client_with(&db, "audit-revoke", "2026-06-21T14:01:00Z")
        .expect("revoke client");

    assert_eq!(response.client_id, "viewer");
    assert_eq!(response.revoked_at, "2026-06-21T14:01:00Z");
    assert!(db
        .verify_remote_client_token("viewer", "viewer-token-secret")
        .expect("verify revoked client")
        .is_none());
    assert!(
        args.revoke_client_with(&db, "audit-revoke-again", "2026-06-21T14:01:30Z")
            .is_err(),
        "revoke must fail for already revoked clients"
    );

    let events = db.load_remote_audit_events(10).expect("audit events");
    assert!(events
        .iter()
        .any(|event| event.route_or_method == "remote.clients.revoke"
            && event.client_id.as_deref() == Some("viewer")));
}

#[test]
fn daemon_remote_clients_rotate_returns_new_token_and_audits() {
    let db = DaemonDb::open_in_memory().expect("open db");
    register_remote_client(
        &db,
        "operator",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
        "old-token-secret",
    );
    let args = DaemonRemoteClientIdArgs {
        client_id: "operator".to_string(),
    };

    let response = args
        .rotate_client_with(
            &db,
            "manual-rotated-token-secret",
            "audit-rotate",
            "2026-06-21T14:02:00Z",
        )
        .expect("rotate client");

    assert_eq!(response.client_id, "operator");
    assert_eq!(response.token, "manual-rotated-token-secret");
    assert_eq!(response.token_hint, "secret");
    assert_eq!(response.rotated_at, "2026-06-21T14:02:00Z");
    assert!(db
        .verify_remote_client_token("operator", "old-token-secret")
        .expect("old token rejected")
        .is_none());
    assert!(db
        .verify_remote_client_token("operator", "manual-rotated-token-secret")
        .expect("new token accepted")
        .is_some());
    let json = serde_json::to_string(&response).expect("serialize rotate response");
    assert!(!json.contains("sha256:"));

    let events = db.load_remote_audit_events(10).expect("audit events");
    assert!(events
        .iter()
        .any(|event| event.route_or_method == "remote.clients.rotate"
            && event.client_id.as_deref() == Some("operator")));
}

fn register_remote_client(
    db: &DaemonDb,
    client_id: &str,
    role: RemoteRole,
    scopes: &[RemoteAccessScope],
    token: &str,
) {
    let registration = RemoteClientRegistration::new_for_tests(
        client_id,
        format!("{client_id} display"),
        "macos",
        role,
        scopes,
        token,
        "2026-06-21T13:50:00Z",
    )
    .expect("registration");
    db.register_remote_client(&registration)
        .expect("register remote client");
}
