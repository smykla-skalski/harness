use std::error::Error;

use super::remote::{RemoteAcmeChallenge, RemoteDaemonServeConfig, RemoteDnsProvider};
use super::remote_acme::{
    AcmeHttp01ChallengeStore, Dns01ProviderAction, RemoteAcmeRuntimeState, RemoteCertificateBundle,
    RemoteCertificateSlot, RemoteRenewalOutcome, build_remote_acme_runtime_plan,
};

fn tls_alpn_config() -> RemoteDaemonServeConfig {
    RemoteDaemonServeConfig {
        domain: "daemon.example.com".to_string(),
        host: "0.0.0.0".to_string(),
        https_port: 443,
        http_port: 80,
        acme_email: "ops@example.com".to_string(),
        acme_challenge: RemoteAcmeChallenge::TlsAlpn,
        acme_dns_provider: None,
    }
}

#[test]
fn remote_tls_acme_plan_requires_persisted_state() {
    let error =
        build_remote_acme_runtime_plan(&tls_alpn_config(), &RemoteAcmeRuntimeState::default())
            .expect_err("remote mode should fail closed without persisted ACME state");

    assert!(error.to_string().contains("persisted ACME state"));
}

#[test]
fn remote_tls_acme_plan_rejects_blank_persisted_account_id() {
    let state = RemoteAcmeRuntimeState::with_account_and_certificate(
        "   ",
        RemoteCertificateBundle::new_for_tests("cert-a", "key-a"),
    );
    let error = build_remote_acme_runtime_plan(&tls_alpn_config(), &state)
        .expect_err("blank ACME account id should fail closed");

    assert!(error.to_string().contains("persisted ACME state"));
}

#[test]
fn remote_tls_acme_plan_reports_missing_certificate_after_account_state_loads() {
    let state = RemoteAcmeRuntimeState::with_account("acct-1");
    let error = build_remote_acme_runtime_plan(&tls_alpn_config(), &state)
        .expect_err("account-only ACME state should fail on missing certificate");

    assert!(error.to_string().contains("persisted TLS certificate"));
}

#[test]
fn remote_tls_acme_plan_rejects_blank_persisted_certificate_material() {
    let state = RemoteAcmeRuntimeState::with_account_and_certificate(
        "acct-1",
        RemoteCertificateBundle::new_for_tests("   ", "\n\t"),
    );
    let error = build_remote_acme_runtime_plan(&tls_alpn_config(), &state)
        .expect_err("blank TLS certificate material should fail closed");

    assert!(error.to_string().contains("persisted TLS certificate"));
}

#[test]
fn remote_tls_acme_plan_exposes_invalid_config_error_source() {
    let mut config = tls_alpn_config();
    config.domain.clear();
    let error = build_remote_acme_runtime_plan(&config, &RemoteAcmeRuntimeState::default())
        .expect_err("invalid config should fail before state checks");

    assert!(
        error
            .source()
            .is_some_and(|source| source.to_string().contains("domain is required")),
        "expected invalid config source, got: {error:?}"
    );
}

#[test]
fn remote_tls_acme_plan_uses_rustls_https_and_wss_urls() {
    let state = RemoteAcmeRuntimeState::with_account_and_certificate(
        "acct-1",
        RemoteCertificateBundle::new_for_tests("cert-a", "key-a"),
    );
    let plan = build_remote_acme_runtime_plan(&tls_alpn_config(), &state)
        .expect("persisted ACME state should allow planning");

    assert_eq!(plan.public_https_origin(), "https://daemon.example.com");
    assert_eq!(plan.public_wss_url(), "wss://daemon.example.com/v1/ws");
    assert!(plan.uses_rustls_https());
    assert_eq!(
        plan.https_alpn_protocols(),
        &[b"h2".as_slice(), b"http/1.1".as_slice()]
    );
}

#[test]
fn remote_tls_alpn_challenge_adds_acme_alpn_protocol() {
    let state = RemoteAcmeRuntimeState::with_account_and_certificate(
        "acct-1",
        RemoteCertificateBundle::new_for_tests("cert-a", "key-a"),
    );
    let plan = build_remote_acme_runtime_plan(&tls_alpn_config(), &state)
        .expect("tls-alpn config should plan");

    assert_eq!(plan.challenge_alpn_protocols(), &[b"acme-tls/1".as_slice()]);
}

#[test]
fn remote_http01_challenge_routes_only_well_known_tokens() {
    let store = AcmeHttp01ChallengeStore::from_pairs([("token-1", "token-1.key-auth")]);

    assert_eq!(
        store.response_for_path("/.well-known/acme-challenge/token-1"),
        Some("token-1.key-auth")
    );
    assert_eq!(
        store.response_for_path("/.well-known/acme-challenge/../token-1"),
        None
    );
    assert_eq!(store.response_for_path("/v1/config"), None);
}

#[test]
fn remote_dns01_providers_report_required_operations() {
    let cloudflare = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Cloudflare,
        "_acme-challenge.daemon.example.com",
        "digest",
    );
    let route53 = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Route53,
        "_acme-challenge.daemon.example.com",
        "digest",
    );
    let exec = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Exec,
        "_acme-challenge.daemon.example.com",
        "digest",
    );

    assert_eq!(
        cloudflare.required_secret_names(),
        &["CLOUDFLARE_API_TOKEN"]
    );
    assert_eq!(
        route53.required_secret_names(),
        &["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
    );
    assert_eq!(
        exec.required_secret_names(),
        &["HARNESS_REMOTE_ACME_DNS_EXEC"]
    );
    assert!(
        exec.command_preview()
            .contains("_acme-challenge.daemon.example.com")
    );
}

#[test]
fn remote_certificate_reload_tracks_generation_and_noops_unchanged_bundle() {
    let mut slot =
        RemoteCertificateSlot::new(RemoteCertificateBundle::new_for_tests("cert-a", "key-a"));

    assert_eq!(slot.generation(), 1);
    assert!(!slot.reload(RemoteCertificateBundle::new_for_tests("cert-a", "key-a")));
    assert_eq!(slot.generation(), 1);
    assert!(slot.reload(RemoteCertificateBundle::new_for_tests("cert-b", "key-b")));
    assert_eq!(slot.generation(), 2);
}

#[test]
fn remote_renewal_failure_status_is_reported_without_secret_detail() {
    let outcome = RemoteRenewalOutcome::failure("dns token secret=super-secret-token failed");

    assert!(outcome.is_failure());
    assert!(outcome.report().contains("dns token"));
    assert!(!outcome.report().contains("super-secret-token"));
}

#[test]
fn remote_renewal_failure_redacts_embedded_secret_values() {
    let outcome = RemoteRenewalOutcome::failure(
        "dns https://issuer.example/renew?token=url-secret-token&retry=1 error=secret=nested-secret",
    );

    assert!(outcome.report().contains("retry=1"));
    assert!(!outcome.report().contains("url-secret-token"));
    assert!(!outcome.report().contains("nested-secret"));
}
