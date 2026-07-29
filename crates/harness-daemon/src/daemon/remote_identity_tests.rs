use super::{
    REMOTE_REQUEST_ID_MAX_BYTES, REMOTE_REQUEST_ID_TRUNCATION_MARKER, RemoteAuditEvent,
    RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteBearerToken, RemoteClientRegistration,
    RemoteTokenHash, expand_client_scopes,
};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};

#[test]
fn remote_token_hash_does_not_store_raw_token_and_verifies_constant_width_digest() {
    let hash = RemoteTokenHash::from_token_for_tests("remote-token-secret");

    assert!(!hash.as_storage_value().contains("remote-token-secret"));
    assert!(hash.verify("remote-token-secret"));
    assert!(!hash.verify("remote-token-wrong"));
    assert!(RemoteTokenHash::try_from_storage_value_for_tests(hash.as_storage_value()).is_ok());
    assert!(RemoteTokenHash::try_from_storage_value_for_tests("sha256:abc").is_err());
    assert!(
        RemoteTokenHash::try_from_storage_value_for_tests("remote-token-secret").is_err(),
        "clear-text token strings must not be accepted as stored hashes"
    );
}

#[test]
fn remote_bearer_token_debug_redacts_raw_value() {
    let token = RemoteBearerToken::from_value_for_tests("raw-remote-token-secret");

    assert!(!format!("{token:?}").contains("raw-remote-token-secret"));
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
    assert_eq!(
        expand_client_scopes(RemoteRole::ExecutionCoordinator, &[])
            .expect("executor default scope"),
        vec![RemoteAccessScope::Execute]
    );
    for forbidden in [
        RemoteAccessScope::Read,
        RemoteAccessScope::Write,
        RemoteAccessScope::Admin,
    ] {
        assert!(
            expand_client_scopes(RemoteRole::ExecutionCoordinator, &[forbidden]).is_err(),
            "executor credentials must not inherit generic daemon authority"
        );
    }
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
fn remote_client_registration_redacts_short_token_hints() {
    let registration = RemoteClientRegistration::new_for_tests(
        "client-short",
        "MacBook Air",
        "macos",
        RemoteRole::Viewer,
        &[],
        "short",
        "2026-06-21T12:30:30Z",
    )
    .expect("registration");

    assert_eq!(registration.token_hint(), "<redacted>");
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

#[test]
fn remote_audit_event_bounds_unicode_request_ids_on_a_character_boundary() {
    let request_id = "\u{17c}".repeat(256);
    let event = RemoteAuditEvent::new(
        "event-bounded-request-id",
        "2026-06-21T12:31:00Z",
        Some(request_id.as_str()),
        Some("client-1"),
        "/v1/sessions",
        RemoteAccessScope::Read,
        RemoteAuditScopeDecision::Allowed,
        RemoteAuditOutcome::Success,
        Some("203.0.113.10"),
        None,
    );

    let bounded = event.request_id.expect("bounded request id");
    assert!(bounded.len() <= REMOTE_REQUEST_ID_MAX_BYTES);
    assert!(bounded.ends_with(REMOTE_REQUEST_ID_TRUNCATION_MARKER));
    assert!(bounded.is_char_boundary(bounded.len()));
}
