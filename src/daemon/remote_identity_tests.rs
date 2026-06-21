use super::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteClientRegistration,
    RemoteTokenHash, expand_client_scopes,
};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};

#[test]
fn remote_token_hash_does_not_store_raw_token_and_verifies_constant_width_digest() {
    let hash = RemoteTokenHash::from_token_for_tests("remote-token-secret");

    assert!(!hash.as_storage_value().contains("remote-token-secret"));
    assert!(hash.verify("remote-token-secret"));
    assert!(!hash.verify("remote-token-wrong"));
    assert!(!RemoteTokenHash::from_storage_value_for_tests("sha256:abc").verify("anything"));
}

#[test]
fn role_expansion_defaults_and_rejects_out_of_role_scope_requests() {
    assert_eq!(
        expand_client_scopes(RemoteRole::Viewer, &[]).expect("viewer default scopes"),
        vec![RemoteAccessScope::Read]
    );
    assert_eq!(
        expand_client_scopes(RemoteRole::Operator, &[RemoteAccessScope::Write])
            .expect("operator may request write"),
        vec![RemoteAccessScope::Write]
    );
    assert!(
        expand_client_scopes(RemoteRole::Viewer, &[RemoteAccessScope::Write]).is_err(),
        "viewer must not be able to request write scope"
    );
}

#[test]
fn remote_client_registration_derives_role_bounded_scopes() {
    let registration = RemoteClientRegistration::new_for_tests(
        "client-1",
        "MacBook Pro",
        "macos",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
        "remote-token-secret",
        "2026-06-21T12:30:00Z",
    )
    .expect("registration");

    assert_eq!(
        registration.scopes(),
        &[RemoteAccessScope::Read, RemoteAccessScope::Write]
    );
    assert_eq!(registration.token_hint(), "secret");
}

#[test]
fn remote_audit_event_redacts_secret_error_detail() {
    let event = RemoteAuditEvent::new(
        "event-1",
        "2026-06-21T12:31:00Z",
        Some("request-1"),
        Some("client-1"),
        "/v1/sessions",
        RemoteAccessScope::Write,
        RemoteAuditScopeDecision::Allowed,
        RemoteAuditOutcome::Failure,
        Some("203.0.113.10"),
        Some("upstream token=url-secret&retry=1 secret=nested-secret"),
    );

    assert_eq!(
        event.error_detail(),
        Some("upstream token=<redacted>&retry=1 secret=<redacted>")
    );
}
