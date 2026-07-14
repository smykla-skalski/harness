use std::env;
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant};

use instant_acme::{Account, RetryPolicy};
use rcgen::KeyPair;
use tokio::sync::Notify;
use tokio::time::timeout;

#[path = "remote_acme_issuer_test_support.rs"]
mod support;

use support::{
    ACCOUNT_URL, DIRECTORY_URL, RecordingProvisioner, ScriptedAcmeHttp, acme_happy_path,
    acme_happy_path_for, acme_rejected_order_path, jws_payload,
};

use super::{InstantAcmeIssuer, RemoteAcmeChallengeMaterial};
use crate::daemon::remote::{RemoteAcmeChallenge, RemoteDaemonServeConfig, RemoteDnsProvider};
use crate::daemon::remote_acme_cleanup::RemoteAcmeCleanupTracker;
use crate::daemon::remote_tls::build_remote_tls_server_config;

const PRODUCTION_PROVIDER_CHILD_ENV: &str = "HARNESS_TEST_REMOTE_ACME_PROVIDER_CHILD";
const PRODUCTION_PROVIDER_TEST: &str = "daemon::remote_acme_issuer::tests::production_acme_issuer_installs_rustls_provider_before_client_creation";

#[test]
fn production_acme_issuer_installs_rustls_provider_before_client_creation() {
    if env::var_os(PRODUCTION_PROVIDER_CHILD_ENV).is_none() {
        let output = Command::new(env::current_exe().expect("current unit test executable"))
            .args(["--exact", PRODUCTION_PROVIDER_TEST, "--nocapture"])
            .env(PRODUCTION_PROVIDER_CHILD_ENV, "1")
            .output()
            .expect("run isolated ACME provider test");
        assert!(
            output.status.success(),
            "isolated ACME provider test failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
        return;
    }

    assert!(rustls::crypto::CryptoProvider::get_default().is_none());
    let _issuer = InstantAcmeIssuer::production(RecordingProvisioner::default());

    assert!(rustls::crypto::CryptoProvider::get_default().is_some());
}

#[tokio::test]
async fn instant_acme_issuer_completes_account_order_and_http01_issuance() {
    let http = ScriptedAcmeHttp::new(acme_happy_path());
    let provisioner = RecordingProvisioner::default();
    let issuer = InstantAcmeIssuer::with_account_builder(
        provisioner.clone(),
        DIRECTORY_URL,
        RetryPolicy::new()
            .initial_delay(Duration::ZERO)
            .timeout(Duration::from_secs(1)),
        {
            let http = http.clone();
            move || Ok(Account::builder_with_http(Box::new(http.clone())))
        },
    );
    let config = http_serve_config();

    let account = issuer
        .create_account(config.acme_email.as_str())
        .await
        .expect("create ACME account");
    let bundle = issuer
        .issue_certificate(&account, &config, None)
        .await
        .expect("issue ACME certificate");

    assert_eq!(account.account_id(), ACCOUNT_URL);
    assert!(account.serialized().contains("key_pkcs8"));
    assert!(bundle.certificate_pem().contains("BEGIN CERTIFICATE"));
    assert!(bundle.private_key_pem().contains("BEGIN PRIVATE KEY"));
    build_remote_tls_server_config(&bundle)
        .expect("fake CA certificate must match finalized private key");
    let materials = provisioner.materials();
    assert_eq!(materials.len(), 1);
    let RemoteAcmeChallengeMaterial::Http01 {
        domain,
        bind_host,
        port,
        token,
        key_authorization,
    } = &materials[0]
    else {
        panic!("issuer selected wrong challenge material");
    };
    assert_eq!(domain, "daemon.example.com");
    assert_eq!(bind_host, "0.0.0.0");
    assert_eq!(*port, 80);
    assert_eq!(token, "http-token");
    assert!(key_authorization.starts_with("http-token."));
    assert_eq!(provisioner.cleanup_count(), 1);

    let requests = http.requests();
    assert_eq!(requests.len(), 12);
    assert_eq!(
        jws_payload(&requests[2])["contact"][0],
        "mailto:ops@example.com"
    );
    assert_eq!(
        jws_payload(&requests[5])["identifiers"][0]["value"],
        "daemon.example.com"
    );
    assert!(
        jws_payload(&requests[9])["csr"]
            .as_str()
            .is_some_and(|csr| !csr.is_empty())
    );
    http.assert_exhausted();
}

#[tokio::test]
async fn instant_acme_issuer_cleans_challenge_when_issuance_is_cancelled() {
    let (http, blocker) =
        ScriptedAcmeHttp::new_blocking(acme_happy_path(), "https://acme.test/order/1");
    let provisioner = RecordingProvisioner::with_cleanup_delay(Duration::from_secs(1));
    let issuer = test_issuer(http, provisioner.clone());
    let config = http_serve_config();
    let account = issuer
        .create_account(config.acme_email.as_str())
        .await
        .expect("create ACME account");
    let cleanup_tracker = RemoteAcmeCleanupTracker::default();
    let task_cleanup_tracker = cleanup_tracker.clone();
    let task = tokio::spawn(async move {
        issuer
            .issue_certificate_with_cleanup(&account, &config, None, task_cleanup_tracker)
            .await
    });

    timeout(Duration::from_secs(5), blocker.wait_until_blocked())
        .await
        .expect("ACME order poll did not block");
    let cancel_started = Instant::now();
    task.abort();
    let cancellation = timeout(Duration::from_secs(2), task)
        .await
        .expect("cancel ACME issuance timeout")
        .expect_err("cancelled ACME issuance should not complete");
    let cancel_elapsed = cancel_started.elapsed();

    assert!(cancellation.is_cancelled());
    assert!(
        cancel_elapsed < Duration::from_millis(500),
        "cancelling ACME issuance blocked for {cancel_elapsed:?}"
    );
    timeout(Duration::from_secs(2), cleanup_tracker.wait_for_cleanup())
        .await
        .expect("cancelled ACME cleanup timeout");
    assert_eq!(provisioner.cleanup_count(), 1);
}

#[tokio::test]
async fn instant_acme_issuer_cleanup_does_not_block_runtime() {
    let http = ScriptedAcmeHttp::new(acme_happy_path());
    let provisioner = RecordingProvisioner::with_cleanup_delay(Duration::from_secs(1));
    let issuer = test_issuer(http, provisioner.clone());
    let config = http_serve_config();
    let account = issuer
        .create_account(config.acme_email.as_str())
        .await
        .expect("create ACME account");
    let task = tokio::spawn(async move { issuer.issue_certificate(&account, &config, None).await });

    timeout(Duration::from_millis(500), async {
        while !provisioner.cleanup_started() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("ACME cleanup blocked the runtime worker");
    timeout(Duration::from_secs(2), task)
        .await
        .expect("ACME issuance cleanup timeout")
        .expect("join ACME issuance")
        .expect("issue ACME certificate");

    assert_eq!(provisioner.cleanup_count(), 1);
}

#[tokio::test]
async fn instant_acme_issuer_returns_success_before_cleanup_visibility_confirmation() {
    let http = ScriptedAcmeHttp::new(acme_happy_path());
    let cleanup_release = Arc::new(Notify::new());
    let provisioner = RecordingProvisioner::with_cleanup_gate(Arc::clone(&cleanup_release));
    let issuer = test_issuer(http, provisioner.clone());
    let config = http_serve_config();
    let account = issuer
        .create_account(config.acme_email.as_str())
        .await
        .expect("create ACME account");
    let cleanup_tracker = RemoteAcmeCleanupTracker::default();
    let task_cleanup_tracker = cleanup_tracker.clone();
    let task = tokio::spawn(async move {
        issuer
            .issue_certificate_with_cleanup(&account, &config, None, task_cleanup_tracker)
            .await
    });

    timeout(Duration::from_secs(2), async {
        while !provisioner.cleanup_started() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("successful issuance did not start cleanup");
    let completed_before_cleanup = timeout(Duration::from_millis(250), async {
        while !task.is_finished() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .is_ok();

    cleanup_release.notify_one();
    timeout(Duration::from_secs(2), cleanup_tracker.wait_for_cleanup())
        .await
        .expect("tracked cleanup did not finish");
    timeout(Duration::from_secs(2), task)
        .await
        .expect("issuance task did not finish")
        .expect("join issuance task")
        .expect("issue ACME certificate");

    assert!(
        completed_before_cleanup,
        "successful issuance waited for authoritative cleanup visibility"
    );
    assert_eq!(provisioner.cleanup_count(), 1);
}

#[tokio::test]
async fn instant_acme_issuer_awaits_success_cleanup_without_tracker() {
    let http = ScriptedAcmeHttp::new(acme_happy_path());
    let cleanup_release = Arc::new(Notify::new());
    let provisioner = RecordingProvisioner::with_cleanup_gate(Arc::clone(&cleanup_release));
    let issuer = test_issuer(http, provisioner.clone());
    let config = http_serve_config();
    let account = issuer
        .create_account(config.acme_email.as_str())
        .await
        .expect("create ACME account");
    let task = tokio::spawn(async move { issuer.issue_certificate(&account, &config, None).await });

    timeout(Duration::from_secs(2), async {
        while !provisioner.cleanup_started() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("successful issuance did not start cleanup");
    assert!(
        !task.is_finished(),
        "untracked issuance returned before cleanup finished"
    );

    cleanup_release.notify_one();
    timeout(Duration::from_secs(2), task)
        .await
        .expect("issuance cleanup did not finish")
        .expect("join issuance task")
        .expect("issue ACME certificate");

    assert_eq!(provisioner.cleanup_count(), 1);
}

#[tokio::test]
async fn instant_acme_issuer_reuses_persisted_private_key_for_renewal() {
    let http = ScriptedAcmeHttp::new(acme_happy_path());
    let provisioner = RecordingProvisioner::default();
    let issuer = test_issuer(http.clone(), provisioner);
    let config = http_serve_config();
    let account = issuer
        .create_account(config.acme_email.as_str())
        .await
        .expect("create ACME account");
    let private_key_pem = KeyPair::generate()
        .expect("generate persisted key")
        .serialize_pem();

    let bundle = issuer
        .issue_certificate(&account, &config, Some(private_key_pem.as_str()))
        .await
        .expect("renew ACME certificate");

    assert_eq!(bundle.private_key_pem(), private_key_pem);
    build_remote_tls_server_config(&bundle)
        .expect("renewed certificate must match the persisted private key");
    http.assert_exhausted();
}

#[tokio::test]
async fn instant_acme_issuer_selects_dns01_material() {
    let (materials, cleanup_count) = issue_for_challenge(RemoteAcmeChallenge::Dns).await;

    let RemoteAcmeChallengeMaterial::Dns01 {
        domain,
        provider,
        record_name,
        record_value,
    } = &materials[0]
    else {
        panic!("issuer selected wrong DNS challenge material");
    };
    assert_eq!(domain, "daemon.example.com");
    assert_eq!(*provider, RemoteDnsProvider::Cloudflare);
    assert_eq!(record_name, "_acme-challenge.daemon.example.com");
    assert!(!record_value.is_empty());
    assert_eq!(cleanup_count, 1);
}

#[tokio::test]
async fn instant_acme_issuer_selects_tls_alpn01_material() {
    let (materials, cleanup_count) = issue_for_challenge(RemoteAcmeChallenge::TlsAlpn).await;

    let RemoteAcmeChallengeMaterial::TlsAlpn01 {
        domain,
        bind_host,
        port,
        digest,
    } = &materials[0]
    else {
        panic!("issuer selected wrong TLS-ALPN challenge material");
    };
    assert_eq!(domain, "daemon.example.com");
    assert_eq!(bind_host, "0.0.0.0");
    assert_eq!(*port, 443);
    assert_eq!(digest.len(), 32);
    assert_eq!(cleanup_count, 1);
}

#[tokio::test]
async fn instant_acme_issuer_cleans_challenge_after_rejected_order() {
    let http = ScriptedAcmeHttp::new(acme_rejected_order_path());
    let provisioner = RecordingProvisioner::default();
    let issuer = test_issuer(http.clone(), provisioner.clone());
    let config = http_serve_config();
    let account = issuer
        .create_account(config.acme_email.as_str())
        .await
        .expect("create ACME account");

    issuer
        .issue_certificate(&account, &config, None)
        .await
        .expect_err("rejected order must fail issuance");

    assert_eq!(provisioner.cleanup_count(), 1);
    http.assert_exhausted();
}

#[tokio::test]
async fn instant_acme_issuer_awaits_cleanup_after_readiness_failure() {
    let http = ScriptedAcmeHttp::new(acme_happy_path());
    let cleanup_release = Arc::new(Notify::new());
    let provisioner = RecordingProvisioner::with_wait_ready_error_and_cleanup_gate(
        "authoritative DNS visibility timed out",
        Arc::clone(&cleanup_release),
    );
    let issuer = test_issuer(http, provisioner.clone());
    let config = http_serve_config();
    let account = issuer
        .create_account(config.acme_email.as_str())
        .await
        .expect("create ACME account");
    let task = tokio::spawn(async move { issuer.issue_certificate(&account, &config, None).await });

    timeout(Duration::from_secs(2), async {
        while !provisioner.cleanup_started() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("readiness failure did not start cleanup");
    assert!(
        !task.is_finished(),
        "issuance returned before cleanup finished"
    );

    cleanup_release.notify_one();
    let error = timeout(Duration::from_secs(2), task)
        .await
        .expect("readiness cleanup timeout")
        .expect("join ACME issuance")
        .expect_err("readiness failure must fail issuance");

    assert_eq!(error, "authoritative DNS visibility timed out");
    assert_eq!(provisioner.cleanup_count(), 1);
}

#[tokio::test]
async fn instant_acme_issuer_redacts_challenge_cleanup_failure() {
    let http = ScriptedAcmeHttp::new(acme_rejected_order_path());
    let provisioner = RecordingProvisioner::with_cleanup_error(
        "provider cleanup token=cleanup-secret secret=nested-secret",
    );
    let issuer = test_issuer(http.clone(), provisioner.clone());
    let config = http_serve_config();
    let account = issuer
        .create_account(config.acme_email.as_str())
        .await
        .expect("create ACME account");

    let error = issuer
        .issue_certificate(&account, &config, None)
        .await
        .expect_err("rejected order and cleanup must fail issuance");

    assert_eq!(provisioner.cleanup_count(), 1);
    assert!(error.contains("cleanup also failed"));
    assert!(error.contains("<redacted>"));
    assert!(!error.contains("cleanup-secret"));
    assert!(!error.contains("nested-secret"));
    http.assert_exhausted();
}

async fn issue_for_challenge(
    challenge: RemoteAcmeChallenge,
) -> (Vec<RemoteAcmeChallengeMaterial>, usize) {
    let http = ScriptedAcmeHttp::new(acme_happy_path_for(challenge));
    let provisioner = RecordingProvisioner::default();
    let issuer = InstantAcmeIssuer::with_account_builder(
        provisioner.clone(),
        DIRECTORY_URL,
        RetryPolicy::new()
            .initial_delay(Duration::ZERO)
            .timeout(Duration::from_secs(1)),
        {
            let http = http.clone();
            move || Ok(Account::builder_with_http(Box::new(http.clone())))
        },
    );
    let config = serve_config(challenge);
    let account = issuer
        .create_account(config.acme_email.as_str())
        .await
        .expect("create ACME account");
    issuer
        .issue_certificate(&account, &config, None)
        .await
        .expect("issue ACME certificate");
    http.assert_exhausted();
    (provisioner.materials(), provisioner.cleanup_count())
}

fn test_issuer(
    http: ScriptedAcmeHttp,
    provisioner: RecordingProvisioner,
) -> InstantAcmeIssuer<RecordingProvisioner> {
    InstantAcmeIssuer::with_account_builder(
        provisioner,
        DIRECTORY_URL,
        RetryPolicy::new()
            .initial_delay(Duration::ZERO)
            .timeout(Duration::from_secs(1)),
        move || Ok(Account::builder_with_http(Box::new(http.clone()))),
    )
}

fn http_serve_config() -> RemoteDaemonServeConfig {
    serve_config(RemoteAcmeChallenge::Http)
}

fn serve_config(challenge: RemoteAcmeChallenge) -> RemoteDaemonServeConfig {
    RemoteDaemonServeConfig {
        domain: "daemon.example.com".to_string(),
        host: "0.0.0.0".to_string(),
        https_port: 443,
        http_port: 80,
        acme_email: "ops@example.com".to_string(),
        acme_challenge: challenge,
        acme_dns_provider: (challenge == RemoteAcmeChallenge::Dns)
            .then_some(RemoteDnsProvider::Cloudflare),
    }
}
