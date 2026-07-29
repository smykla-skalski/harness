use crate::daemon::db::DaemonDb;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::RemoteClientRegistration;

use super::super::remote::{DaemonRemoteClientIdArgs, DaemonRemoteClientsCommand};

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
    assert!(
        db.verify_remote_client_token("viewer", "viewer-token-secret")
            .expect("verify revoked client")
            .is_none()
    );
    assert!(
        args.revoke_client_with(&db, "audit-revoke-again", "2026-06-21T14:01:30Z")
            .is_err(),
        "revoke must fail for already revoked clients"
    );

    let events = db.load_remote_audit_events(10).expect("audit events");
    assert!(events.iter().any(|event| {
        event.route_or_method == "remote.clients.revoke"
            && event.client_id.as_deref() == Some("viewer")
    }));
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
    assert!(
        db.verify_remote_client_token("operator", "old-token-secret")
            .expect("old token rejected")
            .is_none()
    );
    assert!(
        db.verify_remote_client_token("operator", "manual-rotated-token-secret")
            .expect("new token accepted")
            .is_some()
    );
    let json = serde_json::to_string(&response).expect("serialize rotate response");
    assert!(!json.contains("sha256:"));

    let events = db.load_remote_audit_events(10).expect("audit events");
    assert!(events.iter().any(|event| {
        event.route_or_method == "remote.clients.rotate"
            && event.client_id.as_deref() == Some("operator")
    }));
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
