use clap::Parser;
use harness_testkit::with_isolated_harness_env;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::db::DaemonDb;
use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::state;

use super::super::remote::{DaemonRemoteCommand, DaemonRemoteServeArgs};
use super::super::remote_serve::{
    RemoteServeRuntimeMode, build_remote_serve_execution_plan, execute_remote_serve_with,
    remote_serve_runtime_mode,
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
}

#[test]
fn daemon_remote_serve_execute_requires_persisted_acme_state() {
    let temp = tempfile::tempdir().expect("temp dir");
    with_isolated_harness_env(temp.path(), || {
        state::ensure_daemon_dirs().expect("daemon dirs");
        let command = DaemonRemoteCommand::Serve(remote_serve_args());

        let error = command
            .execute(&AppContext)
            .expect_err("remote serve should fail closed before starting");
        let message = error.to_string();

        assert!(message.contains("persisted ACME state"));
        assert!(!message.contains("reserved"));
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
            "UPDATE remote_acme_state
             SET account_id = 'acct-1',
                 certificate_pem = 'cert-pem',
                 private_key_pem = 'key-secret',
                 certificate_fingerprint = 'stored-fp',
                 renewal_status = 'succeeded',
                 renewal_error = NULL,
                 updated_at = '2026-06-21T15:00:00Z'
             WHERE singleton = 1",
            [],
        )
        .expect("seed acme state");
}
