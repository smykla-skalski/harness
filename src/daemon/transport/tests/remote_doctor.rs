use crate::daemon::db::DaemonDb;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::RemoteClientRegistration;

use super::super::remote_doctor::run_remote_doctor_with;

#[test]
fn daemon_remote_doctor_reports_missing_remote_readiness_and_audits() {
    let db = DaemonDb::open_in_memory().expect("open db");

    let response = run_remote_doctor_with(&db, "audit-remote-doctor", "2026-06-21T16:00:00Z")
        .expect("remote doctor response");

    assert_eq!(response.status, "not_ready");
    assert_check(&response, "acme_account", "fail", "persisted ACME account");
    assert_check(
        &response,
        "tls_certificate",
        "fail",
        "persisted TLS certificate",
    );
    assert_check(&response, "acme_renewal", "warn", "no renewal result");
    assert_check(
        &response,
        "remote_clients",
        "warn",
        "no active remote clients",
    );
    assert!(!response.summary.acme_account_configured);
    assert!(!response.summary.certificate_configured);
    assert_eq!(response.summary.active_client_count, 0);
    assert_eq!(response.summary.revoked_client_count, 0);

    let json = serde_json::to_string(&response).expect("serialize response");
    assert!(!json.contains("private_key"));
    assert!(!json.contains("secret"));
    assert!(!json.contains("reserved"));

    let events = db.load_remote_audit_events(10).expect("audit events");
    assert!(events.iter().any(|event| {
        event.route_or_method == "remote.doctor"
            && event.scope.as_str() == "read"
            && event.outcome.as_str() == "success"
    }));
}

#[test]
fn daemon_remote_doctor_reports_ready_state_without_secret_material() {
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
    register_client(&db, "client-active", None);
    register_client(&db, "client-revoked", Some("2026-06-21T15:15:00Z"));

    let response = run_remote_doctor_with(&db, "audit-remote-doctor", "2026-06-21T16:00:00Z")
        .expect("remote doctor response");

    assert_eq!(response.status, "ready");
    assert_check(&response, "acme_account", "pass", "configured");
    assert_check(&response, "tls_certificate", "pass", "configured");
    assert_check(&response, "acme_renewal", "pass", "succeeded");
    assert_check(&response, "remote_clients", "pass", "1 active");
    assert!(response.summary.acme_account_configured);
    assert!(response.summary.certificate_configured);
    assert_eq!(
        response.summary.certificate_fingerprint.as_deref(),
        Some("fp-1")
    );
    assert_eq!(response.summary.active_client_count, 1);
    assert_eq!(response.summary.revoked_client_count, 1);

    let json = serde_json::to_string(&response).expect("serialize response");
    assert!(json.contains("\"certificate_fingerprint\":\"fp-1\""));
    assert!(!json.contains("key-secret"));
    assert!(!json.contains("cert-pem"));
}

fn assert_check(
    response: &super::super::remote_doctor::DaemonRemoteDoctorResponse,
    name: &str,
    status: &str,
    detail: &str,
) {
    let check = response
        .checks
        .iter()
        .find(|check| check.name == name)
        .unwrap_or_else(|| panic!("missing check {name}"));
    assert_eq!(check.status, status);
    assert!(
        check.detail.contains(detail),
        "expected {name} detail to contain {detail:?}, got {:?}",
        check.detail
    );
}

fn register_client(db: &DaemonDb, client_id: &str, revoked_at: Option<&str>) {
    let registration = RemoteClientRegistration::new_for_tests(
        client_id,
        "MacBook",
        "macos",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        &format!("token-{client_id}"),
        "2026-06-21T15:00:00Z",
    )
    .expect("registration");
    db.register_remote_client(&registration)
        .expect("register client");
    if let Some(revoked_at) = revoked_at {
        assert!(
            db.revoke_remote_client(client_id, revoked_at)
                .expect("revoke client")
        );
    }
}
