use clap::Parser;

use crate::daemon::db::DaemonDb;

use super::super::remote::{DaemonRemoteAcmeCommand, DaemonRemoteCommand};

#[derive(Debug, Parser)]
struct DaemonRemoteCommandTestHarness {
    #[command(subcommand)]
    command: DaemonRemoteCommand,
}

#[test]
fn daemon_remote_acme_cli_parses_status_and_renew() {
    let status = DaemonRemoteCommandTestHarness::try_parse_from(["test", "acme", "status"])
        .expect("parse acme status")
        .command;
    let renew = DaemonRemoteCommandTestHarness::try_parse_from(["test", "acme", "renew"])
        .expect("parse acme renew")
        .command;

    assert!(matches!(
        status,
        DaemonRemoteCommand::Acme {
            command: DaemonRemoteAcmeCommand::Status
        }
    ));
    assert!(matches!(
        renew,
        DaemonRemoteCommand::Acme {
            command: DaemonRemoteAcmeCommand::Renew
        }
    ));
}

#[test]
fn daemon_remote_acme_status_reports_persisted_state_without_key() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.connection()
        .execute(
            "UPDATE remote_acme_state
             SET account_id = 'acct-1',
                 certificate_pem = 'cert-pem',
                 private_key_pem = 'key-secret',
                 certificate_fingerprint = 'fp-1',
                 renewal_status = 'succeeded',
                 renewal_error = NULL,
                 updated_at = '2026-06-21T15:10:00Z'
             WHERE singleton = 1",
            [],
        )
        .expect("seed acme state");

    let response = DaemonRemoteAcmeCommand::Status
        .status_with(&db, "audit-acme-status", "2026-06-21T15:11:00Z")
        .expect("status response");

    assert!(response.account_configured);
    assert_eq!(response.account_id.as_deref(), Some("acct-1"));
    assert!(response.certificate_configured);
    assert_eq!(response.certificate_fingerprint.as_deref(), Some("fp-1"));
    assert_eq!(response.renewal_status, "succeeded");
    let json = serde_json::to_string(&response).expect("serialize response");
    assert!(!json.contains("key-secret"));

    let routes: Vec<_> = db
        .load_remote_audit_events(10)
        .expect("audit events")
        .into_iter()
        .map(|event| event.route_or_method)
        .collect();
    assert_eq!(routes, vec!["remote.acme.status"]);
}

#[test]
fn daemon_remote_acme_renew_records_missing_state_failure_and_audit() {
    let db = DaemonDb::open_in_memory().expect("open db");

    let response = DaemonRemoteAcmeCommand::Renew
        .renew_with(&db, "audit-acme-renew", "2026-06-21T15:12:00Z")
        .expect("renew response");

    assert_eq!(response.renewal_status, "failed");
    assert!(
        response
            .renewal_error
            .as_deref()
            .is_some_and(|error| error.contains("persisted ACME state"))
    );

    let state = db.load_remote_acme_state().expect("load acme state");
    assert_eq!(state.renewal_status.as_str(), "failed");
    assert_eq!(state.updated_at, "2026-06-21T15:12:00Z");
    let json = serde_json::to_string(&response).expect("serialize renew response");
    assert!(json.contains("\"updated_at\""));
    assert!(!json.contains("\"renewed_at\""));
    let error = response
        .ensure_success()
        .expect_err("failure renewal response must produce a command error");
    assert!(error.to_string().contains("persisted ACME state"));
    assert!(!error.to_string().contains("did not succeed"));

    let events = db.load_remote_audit_events(10).expect("audit events");
    assert!(events.iter().any(|event| {
        event.route_or_method == "remote.acme.renew" && event.outcome.as_str() == "failure"
    }));
}
