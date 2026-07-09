use std::error::Error;

use super::{
    AcmeHttp01ChallengeStore, Dns01ChangeOperation, Dns01ExecHookOperation, Dns01ProviderAction,
    RemoteAcmeRuntimeState, RemoteCertificateBundle, RemoteCertificateSlot, RemoteRenewalOutcome,
    build_remote_acme_runtime_plan,
};
use crate::daemon::remote::{RemoteAcmeChallenge, RemoteDaemonServeConfig, RemoteDnsProvider};

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
fn remote_dns01_cloudflare_builds_present_and_cleanup_requests() {
    let action = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Cloudflare,
        "_acme-challenge.daemon.example.com",
        "digest-value",
    );

    let present = action
        .cloudflare_change_request("zone-123", Dns01ChangeOperation::Present)
        .expect("cloudflare present request");
    let cleanup = action
        .cloudflare_change_request("zone-123", Dns01ChangeOperation::Cleanup)
        .expect("cloudflare cleanup request");

    assert_eq!(present.zone_id(), "zone-123");
    assert_eq!(present.record_type(), "TXT");
    assert_eq!(present.name(), "_acme-challenge.daemon.example.com");
    assert_eq!(present.content(), "digest-value");
    assert_eq!(present.ttl_seconds(), 120);
    assert_eq!(present.operation().as_str(), "present");
    assert_eq!(cleanup.operation().as_str(), "cleanup");
}

#[test]
fn remote_dns01_route53_builds_present_and_cleanup_change_batches() {
    let action = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Route53,
        "_acme-challenge.daemon.example.com",
        "digest-value",
    );

    let present = action
        .route53_change_batch("Z123456", Dns01ChangeOperation::Present)
        .expect("route53 present change");
    let cleanup = action
        .route53_change_batch("Z123456", Dns01ChangeOperation::Cleanup)
        .expect("route53 cleanup change");

    assert_eq!(present.hosted_zone_id(), "Z123456");
    assert_eq!(present.record_type(), "TXT");
    assert_eq!(present.name(), "_acme-challenge.daemon.example.com.");
    assert_eq!(present.quoted_value(), "\"digest-value\"");
    assert_eq!(present.ttl_seconds(), 60);
    assert_eq!(present.action(), "UPSERT");
    assert_eq!(cleanup.action(), "DELETE");
}

#[test]
fn remote_dns01_native_provider_requests_validate_provider_and_zone_ids() {
    let cloudflare = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Cloudflare,
        "_acme-challenge.daemon.example.com",
        "digest-value",
    );
    let route53 = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Route53,
        "_acme-challenge.daemon.example.com",
        "digest-value",
    );

    let missing_zone = cloudflare
        .cloudflare_change_request("  ", Dns01ChangeOperation::Present)
        .expect_err("cloudflare zone id is required");
    assert!(missing_zone.to_string().contains("zone id is required"));

    let wrong_provider = route53
        .cloudflare_change_request("zone-123", Dns01ChangeOperation::Present)
        .expect_err("route53 cannot build cloudflare requests");
    assert!(
        wrong_provider
            .to_string()
            .contains("cloudflare DNS provider")
    );

    let missing_hosted_zone = route53
        .route53_change_batch("  ", Dns01ChangeOperation::Present)
        .expect_err("route53 hosted zone id is required");
    assert!(
        missing_hosted_zone
            .to_string()
            .contains("hosted zone id is required")
    );

    let blank_route53_name =
        Dns01ProviderAction::for_provider(RemoteDnsProvider::Route53, "   ", "digest-value");
    let missing_name = blank_route53_name
        .route53_change_batch("Z123456", Dns01ChangeOperation::Present)
        .expect_err("route53 record name is required");
    assert!(missing_name.to_string().contains("record name is required"));
}

#[test]
fn remote_dns01_exec_hook_invokes_present_and_cleanup_commands() {
    let action = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Exec,
        "_acme-challenge.daemon.example.com",
        "digest-value",
    );

    let mut invocations = Vec::new();
    action
        .run_exec_hook_with(
            "/usr/local/bin/harness-acme-dns",
            Dns01ExecHookOperation::Present,
            |invocation| {
                invocations.push(invocation.clone());
                Ok(())
            },
        )
        .expect("present hook");
    action
        .run_exec_hook_with(
            "/usr/local/bin/harness-acme-dns",
            Dns01ExecHookOperation::Cleanup,
            |invocation| {
                invocations.push(invocation.clone());
                Ok(())
            },
        )
        .expect("cleanup hook");

    assert_eq!(invocations.len(), 2);
    assert_eq!(invocations[0].program(), "/usr/local/bin/harness-acme-dns");
    assert_eq!(
        invocations[0].args(),
        &[
            "present",
            "_acme-challenge.daemon.example.com",
            "digest-value"
        ]
    );
    assert_eq!(
        invocations[1].args(),
        &[
            "cleanup",
            "_acme-challenge.daemon.example.com",
            "digest-value"
        ]
    );
}

#[test]
fn remote_dns01_exec_hook_rejects_invalid_provider_and_blank_program() {
    let cloudflare = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Cloudflare,
        "_acme-challenge.daemon.example.com",
        "digest-value",
    );
    let exec = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Exec,
        "_acme-challenge.daemon.example.com",
        "digest-value",
    );

    let wrong_provider = cloudflare
        .run_exec_hook_with(
            "/usr/local/bin/harness-acme-dns",
            Dns01ExecHookOperation::Present,
            |_| Ok(()),
        )
        .expect_err("cloudflare cannot run exec hook");
    assert!(wrong_provider.to_string().contains("exec DNS provider"));

    let blank_program = exec
        .run_exec_hook_with("  ", Dns01ExecHookOperation::Present, |_| Ok(()))
        .expect_err("blank hook program should fail");
    assert!(
        blank_program
            .to_string()
            .contains("hook command is required")
    );
}

#[test]
fn remote_dns01_exec_hook_redacts_runner_failure_detail() {
    let action = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Exec,
        "_acme-challenge.daemon.example.com",
        "digest-value",
    );

    let error = action
        .run_exec_hook_with(
            "/usr/local/bin/harness-acme-dns",
            Dns01ExecHookOperation::Present,
            |_| Err("dns hook failed token=super-secret".to_string()),
        )
        .expect_err("runner failure should surface");

    assert!(error.to_string().contains("dns hook failed"));
    assert!(!error.to_string().contains("super-secret"));
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
fn remote_certificate_bundle_debug_redacts_pem_material() {
    let bundle = RemoteCertificateBundle::new_for_tests(
        "-----BEGIN CERTIFICATE-----cert-secret",
        "-----BEGIN PRIVATE KEY-----key-secret",
    );
    let debug = format!("{bundle:?}");

    assert!(debug.contains("<redacted>"));
    assert!(!debug.contains("cert-secret"));
    assert!(!debug.contains("key-secret"));
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
