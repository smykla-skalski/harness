use clap::Parser;
use harness_testkit::with_isolated_harness_env;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::daemon::db::DaemonDb;
use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::remote::RemoteDaemonServeConfig;
use crate::daemon::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeRenewalIssuer, RemoteAcmeRenewalRequest,
    RemoteCertificateBundle,
};

use super::super::remote::DaemonRemoteServeArgs;
use super::super::remote_serve::{
    RemoteServeRuntimeMode, build_remote_serve_execution_plan, execute_remote_serve_with,
    execute_remote_serve_with_issuer, remote_serve_runtime_mode,
};

#[derive(Debug, Parser)]
struct DaemonRemoteServeArgsTestHarness {
    #[command(flatten)]
    args: DaemonRemoteServeArgs,
}

#[test]
fn daemon_remote_serve_execution_plan_requires_persisted_acme_state() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let args = remote_serve_args();

    let error = match build_remote_serve_execution_plan(&args, &db) {
        Ok(_) => panic!("remote serve should fail closed without persisted ACME state"),
        Err(error) => error,
    };
    let message = error.to_string();

    assert!(message.contains("persisted ACME state"));
    assert!(!message.contains("reserved"));

    let stored = db
        .load_remote_acme_state()
        .expect("load persisted remote acme state")
        .serve_config
        .expect("remote serve config should be persisted before ACME preflight fails");
    assert_eq!(stored.domain, "daemon.example.com");
    assert_eq!(stored.host, "0.0.0.0");
    assert_eq!(stored.https_port, 443);
    assert_eq!(stored.http_port, 80);
    assert_eq!(stored.acme_email, "ops@example.com");
}

#[test]
fn daemon_remote_serve_execute_bootstraps_missing_acme_state() {
    let temp = tempfile::tempdir().expect("temp dir");
    with_isolated_harness_env(temp.path(), || {
        let db = DaemonDb::open_in_memory().expect("open db");

        let exit = execute_remote_serve_with_issuer(
            &remote_serve_args(),
            || Ok(db),
            |plan| {
                assert_eq!(plan.service_config.auth_mode, DaemonHttpAuthMode::Remote);
                assert_eq!(
                    plan.acme_plan.certificate().certificate_pem(),
                    "initial-cert-pem"
                );
                Ok(0)
            },
            &ServeInitialIssuer,
            "2026-07-09T18:30:00Z",
        )
        .expect("remote serve should bootstrap certificate and run");

        assert_eq!(exit, 0);
    });
}

#[test]
fn daemon_remote_serve_execution_plan_uses_remote_auth_and_tls() {
    let db = DaemonDb::open_in_memory().expect("open db");
    seed_acme_state(&db);

    let plan = build_remote_serve_execution_plan(&remote_serve_args(), &db)
        .expect("remote serve should plan from persisted TLS state");

    assert_eq!(plan.service_config.host, "0.0.0.0");
    assert_eq!(plan.service_config.port, 443);
    assert_eq!(plan.service_config.auth_mode, DaemonHttpAuthMode::Remote);
    assert_eq!(
        plan.service_config.remote_domain.as_deref(),
        Some("daemon.example.com")
    );
    assert_eq!(
        plan.acme_plan.public_https_origin(),
        "https://daemon.example.com"
    );
    assert_eq!(
        plan.acme_plan.public_wss_url(),
        "wss://daemon.example.com/v1/ws"
    );
    assert!(plan.acme_plan.uses_rustls_https());
    assert!(plan.acme_plan.certificate().has_material());
}

#[test]
fn daemon_remote_serve_execute_invokes_https_runner_after_preflight() {
    let temp = tempfile::tempdir().expect("temp dir");
    with_isolated_harness_env(temp.path(), || {
        let db = DaemonDb::open_in_memory().expect("open db");
        seed_acme_state(&db);

        let exit = execute_remote_serve_with(
            &remote_serve_args(),
            || Ok(db),
            |plan| {
                assert_eq!(plan.service_config.host, "0.0.0.0");
                assert_eq!(plan.service_config.port, 443);
                assert_eq!(
                    plan.acme_plan.public_https_origin(),
                    "https://daemon.example.com"
                );
                assert!(plan.acme_plan.certificate().has_material());
                Ok(0)
            },
        )
        .expect("remote serve should invoke https runner after preflight");

        assert_eq!(exit, 0);
    });
}

#[test]
fn daemon_remote_serve_reissues_certificate_when_domain_changes() {
    let temp = tempfile::tempdir().expect("temp dir");
    with_isolated_harness_env(temp.path(), || {
        let db = DaemonDb::open_in_memory().expect("open db");
        seed_acme_state(&db);
        let mut old_config = remote_serve_args().contract_config().expect("old config");
        old_config.domain = "old-daemon.example.com".to_string();
        db.record_remote_acme_serve_config(&old_config, "2026-07-09T18:29:00Z")
            .expect("persist old serve config");
        let issuer = RecordingServeRenewalIssuer::default();

        execute_remote_serve_with_issuer(
            &remote_serve_args(),
            || Ok(db),
            |plan| {
                assert_eq!(
                    plan.acme_plan.certificate().certificate_pem(),
                    "replacement-cert-pem"
                );
                Ok(0)
            },
            &issuer,
            "2026-07-09T18:30:00Z",
        )
        .expect("domain change should reissue before serving");

        assert_eq!(issuer.renewal_count(), 1);
    });
}

#[test]
fn daemon_remote_serve_runtime_mode_uses_new_runtime_without_current_runtime() {
    assert_eq!(
        remote_serve_runtime_mode(),
        RemoteServeRuntimeMode::NewTokioRuntime
    );
}

#[test]
fn daemon_remote_serve_runtime_mode_detects_existing_tokio_runtime() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("build runtime");

    runtime.block_on(async {
        assert_eq!(
            remote_serve_runtime_mode(),
            RemoteServeRuntimeMode::ExistingTokioRuntime
        );
    });
}

fn remote_serve_args() -> DaemonRemoteServeArgs {
    DaemonRemoteServeArgsTestHarness::try_parse_from([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ])
    .expect("parse remote serve args")
    .args
}

fn seed_acme_state(db: &DaemonDb) {
    db.connection()
        .execute(
            r#"UPDATE remote_acme_state
             SET account_id = 'acct-1',
                 account_credentials_json = '{"id":"acct-1","key_pkcs8":"account-key-secret"}',
                 certificate_pem = 'cert-pem',
                 private_key_pem = 'key-secret',
                 certificate_fingerprint = 'stored-fp',
                 renewal_status = 'succeeded',
                 renewal_error = NULL,
                 updated_at = '2026-06-21T15:00:00Z'
             WHERE singleton = 1"#,
            [],
        )
        .expect("seed acme state");
    let config = remote_serve_args().contract_config().expect("serve config");
    db.record_remote_acme_serve_config(&config, "2026-06-21T15:00:00Z")
        .expect("seed remote serve config");
}

struct ServeInitialIssuer;

impl RemoteAcmeRenewalIssuer for ServeInitialIssuer {
    fn create_account(
        &self,
        config: &RemoteDaemonServeConfig,
    ) -> Result<RemoteAcmeAccountCredentials, String> {
        assert_eq!(config.domain, "daemon.example.com");
        RemoteAcmeAccountCredentials::new(
            "https://acme.test/acct/serve",
            r#"{"id":"https://acme.test/acct/serve","key_pkcs8":"serve-account-key"}"#,
        )
        .map_err(|error| error.to_string())
    }

    fn renew_certificate(
        &self,
        request: &RemoteAcmeRenewalRequest,
    ) -> Result<RemoteCertificateBundle, String> {
        assert_eq!(request.account_id(), "https://acme.test/acct/serve");
        Ok(RemoteCertificateBundle::new_for_tests(
            "initial-cert-pem",
            "initial-key-pem",
        ))
    }
}

#[derive(Clone, Default)]
struct RecordingServeRenewalIssuer {
    renewals: Arc<AtomicUsize>,
}

impl RecordingServeRenewalIssuer {
    fn renewal_count(&self) -> usize {
        self.renewals.load(Ordering::SeqCst)
    }
}

impl RemoteAcmeRenewalIssuer for RecordingServeRenewalIssuer {
    fn create_account(
        &self,
        _config: &RemoteDaemonServeConfig,
    ) -> Result<RemoteAcmeAccountCredentials, String> {
        panic!("domain change must reuse the persisted ACME account")
    }

    fn renew_certificate(
        &self,
        request: &RemoteAcmeRenewalRequest,
    ) -> Result<RemoteCertificateBundle, String> {
        assert_eq!(request.serve_config().domain, "daemon.example.com");
        self.renewals.fetch_add(1, Ordering::SeqCst);
        Ok(RemoteCertificateBundle::new_for_tests(
            "replacement-cert-pem",
            "replacement-key-pem",
        ))
    }
}
