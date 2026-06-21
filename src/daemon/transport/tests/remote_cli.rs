use clap::Parser;

use super::super::{
    DaemonRemoteCommand, DaemonRemotePairCommand, DaemonRemoteServeArgs,
};

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
fn daemon_remote_serve_args_require_tls_identity_inputs() {
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
    assert!(
        DaemonRemoteCommandTestHarness::try_parse_from([
            "test",
            "pair",
            "create",
            "--scopes",
            "read,root",
        ])
        .is_err()
    );
}

#[test]
fn daemon_remote_pair_create_rejects_invalid_ttl() {
    assert!(
        DaemonRemoteCommandTestHarness::try_parse_from([
            "test",
            "pair",
            "create",
            "--ttl",
            "tomorrow",
        ])
        .is_err()
    );
}

#[test]
fn daemon_remote_pair_create_reports_zero_ttl() {
    let error = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "pair",
        "create",
        "--ttl",
        "0m",
    ])
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
