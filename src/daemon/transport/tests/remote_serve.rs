use async_trait::async_trait;
use clap::Parser;
use harness_testkit::with_isolated_harness_env;
use std::future::pending;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread;
use std::time::Duration;
use tokio::sync::{Notify, watch as tokio_watch};
use tokio::time::{sleep, timeout};

use crate::daemon::db::DaemonDb;
use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::remote::RemoteDaemonServeConfig;
use crate::daemon::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeRenewalIssuer, RemoteAcmeRenewalRequest,
    RemoteCertificateBundle,
};
use crate::daemon::remote_acme_cleanup::RemoteAcmeCleanupTracker;
use crate::errors::CliError;

use super::super::remote::DaemonRemoteServeArgs;
use super::super::remote_serve::{
    RemoteServeRuntimeMode, build_remote_serve_execution_plan, execute_remote_serve_with,
    execute_remote_serve_with_issuer, remote_serve_runtime_mode, run_remote_daemon_thread,
};
use super::super::remote_serve_startup::{
    RemoteInitialAcmeControl, RemoteInitialAcmeIssuer, ensure_initial_remote_acme,
    record_initial_acme_shutdown, run_initial_acme_until_shutdown,
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

#[tokio::test]
async fn daemon_remote_initial_acme_shutdown_waits_for_challenge_cleanup() {
    let cleanup_tracker = RemoteAcmeCleanupTracker::default();
    let challenge_presented = Arc::new(Notify::new());
    let cleanup_started = Arc::new(AtomicBool::new(false));
    let cleanup_completed = Arc::new(AtomicBool::new(false));
    let cleanup_on_drop = CleanupOnDrop {
        tracker: cleanup_tracker.clone(),
        started: Arc::clone(&cleanup_started),
        completed: Arc::clone(&cleanup_completed),
    };
    let issuance = {
        let challenge_presented = Arc::clone(&challenge_presented);
        async move {
            let _cleanup_on_drop = cleanup_on_drop;
            challenge_presented.notify_one();
            pending::<Result<(), CliError>>().await
        }
    };
    let (shutdown_tx, shutdown_rx) = tokio_watch::channel(false);
    let shutdown = tokio::spawn(async move {
        challenge_presented.notified().await;
        shutdown_tx.send(true).expect("request startup shutdown");
    });

    let control = timeout(
        Duration::from_secs(2),
        run_initial_acme_until_shutdown(shutdown_rx, &cleanup_tracker, issuance),
    )
    .await
    .expect("initial ACME shutdown should not time out")
    .expect("initial ACME shutdown should succeed");
    shutdown.await.expect("join shutdown request");

    assert_eq!(control, RemoteInitialAcmeControl::ShutdownDuringIssuance);
    assert!(cleanup_started.load(Ordering::SeqCst));
    assert!(cleanup_completed.load(Ordering::SeqCst));
}

#[tokio::test]
async fn daemon_remote_initial_acme_completion_observes_pending_shutdown() {
    let cleanup_tracker = RemoteAcmeCleanupTracker::default();
    let (shutdown_tx, shutdown_rx) = tokio_watch::channel(false);
    let issuance = async move {
        shutdown_tx
            .send(true)
            .expect("request shutdown before issuance completes");
        Ok(())
    };

    let control = run_initial_acme_until_shutdown(shutdown_rx, &cleanup_tracker, issuance)
        .await
        .expect("observe shutdown after issuance");

    assert_eq!(control, RemoteInitialAcmeControl::ShutdownAfterIssuance);
}

#[test]
fn daemon_remote_existing_runtime_thread_has_stable_name() {
    let name =
        run_remote_daemon_thread(|| Ok(thread::current().name().unwrap_or_default().to_string()))
            .expect("run named remote daemon thread");

    assert_eq!(name, "harness-remote-daemon");
}

#[tokio::test]
async fn daemon_remote_initial_acme_shutdown_persists_account_cleanup_and_failure() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let config = remote_serve_args().contract_config().expect("serve config");
    db.record_remote_acme_serve_config(&config, "2026-07-11T10:00:00Z")
        .expect("record serve config");
    let cleanup_tracker = RemoteAcmeCleanupTracker::default();
    let issuer = BlockingInitialIssuer::new(cleanup_tracker.clone());
    let (shutdown_tx, shutdown_rx) = tokio_watch::channel(false);
    let challenge_presented = Arc::clone(&issuer.challenge_presented);
    let shutdown = tokio::spawn(async move {
        challenge_presented.notified().await;
        shutdown_tx.send(true).expect("request startup shutdown");
    });
    let initial_acme = ensure_initial_remote_acme(
        &db,
        &issuer,
        "2026-07-11T10:00:00Z",
        false,
        &cleanup_tracker,
    );

    let control = run_initial_acme_until_shutdown(shutdown_rx, &cleanup_tracker, initial_acme)
        .await
        .expect("cancel initial ACME issuance");
    shutdown.await.expect("join shutdown request");
    record_initial_acme_shutdown(&db, "2026-07-11T10:00:01Z")
        .expect("record initial ACME shutdown");

    assert_eq!(control, RemoteInitialAcmeControl::ShutdownDuringIssuance);
    assert!(issuer.cleanup_started.load(Ordering::SeqCst));
    assert!(issuer.cleanup_completed.load(Ordering::SeqCst));
    let issuance = db
        .load_remote_acme_issuance_state()
        .expect("load ACME issuance state");
    assert_eq!(
        issuance
            .account
            .as_ref()
            .map(|account| account.account_id()),
        Some("https://acme.test/acct/startup")
    );
    let state = db.load_remote_acme_state().expect("load ACME state");
    assert!(!state.certificate_configured);
    assert_eq!(state.renewal_status.as_str(), "failed");
    assert!(
        state
            .renewal_error
            .as_deref()
            .is_some_and(|detail| detail.contains("cancelled during daemon shutdown"))
    );
    let events = db.load_remote_audit_events(10).expect("load audit events");
    assert!(events.iter().any(|event| {
        event.route_or_method == "remote.acme.renew"
            && event.outcome.as_str() == "failure"
            && event
                .error_detail
                .as_deref()
                .is_some_and(|detail| detail.contains("cancelled during daemon shutdown"))
    }));
}

struct CleanupOnDrop {
    tracker: RemoteAcmeCleanupTracker,
    started: Arc<AtomicBool>,
    completed: Arc<AtomicBool>,
}

impl Drop for CleanupOnDrop {
    fn drop(&mut self) {
        let started = Arc::clone(&self.started);
        let completed = Arc::clone(&self.completed);
        drop(self.tracker.spawn_cleanup(async move {
            started.store(true, Ordering::SeqCst);
            sleep(Duration::from_millis(50)).await;
            completed.store(true, Ordering::SeqCst);
            Ok(())
        }));
    }
}

struct BlockingInitialIssuer {
    tracker: RemoteAcmeCleanupTracker,
    challenge_presented: Arc<Notify>,
    cleanup_started: Arc<AtomicBool>,
    cleanup_completed: Arc<AtomicBool>,
}

impl BlockingInitialIssuer {
    fn new(tracker: RemoteAcmeCleanupTracker) -> Self {
        Self {
            tracker,
            challenge_presented: Arc::new(Notify::new()),
            cleanup_started: Arc::new(AtomicBool::new(false)),
            cleanup_completed: Arc::new(AtomicBool::new(false)),
        }
    }
}

#[async_trait]
impl RemoteInitialAcmeIssuer for BlockingInitialIssuer {
    async fn create_account(
        &self,
        config: &RemoteDaemonServeConfig,
    ) -> Result<RemoteAcmeAccountCredentials, String> {
        assert_eq!(config.domain, "daemon.example.com");
        RemoteAcmeAccountCredentials::new(
            "https://acme.test/acct/startup",
            r#"{"id":"https://acme.test/acct/startup","key_pkcs8":"startup-account-key"}"#,
        )
        .map_err(|error| error.to_string())
    }

    async fn renew_certificate(
        &self,
        request: &RemoteAcmeRenewalRequest,
        cleanup_tracker: &RemoteAcmeCleanupTracker,
    ) -> Result<RemoteCertificateBundle, String> {
        assert_eq!(request.account_id(), "https://acme.test/acct/startup");
        assert!(cleanup_tracker.same_operation(&self.tracker));
        let _cleanup_on_drop = CleanupOnDrop {
            tracker: cleanup_tracker.clone(),
            started: Arc::clone(&self.cleanup_started),
            completed: Arc::clone(&self.cleanup_completed),
        };
        self.challenge_presented.notify_one();
        pending().await
    }
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
