use super::{
    validate_pairing_domain, RemotePairingClaimRequest, RemotePairingCode,
    RemotePairingRateLimiter, RemotePairingRecord,
};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};

#[test]
fn remote_pairing_code_hashes_secret_and_redacts_debug() {
    let code = RemotePairingCode::from_value_for_tests("pairing-secret-value");
    let record = RemotePairingRecord::new_for_tests(
        "pairing-1",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
        code.expose(),
        "2026-06-21T13:40:00Z",
        "2026-06-21T13:50:00Z",
    )
    .expect("pairing record");

    assert!(!format!("{code:?}").contains("pairing-secret-value"));
    assert!(!record
        .code_hash
        .as_storage_value()
        .contains("pairing-secret-value"));
    assert!(record.code_hash.verify(code.expose()));
    assert_eq!(
        record.scopes,
        vec![RemoteAccessScope::Read, RemoteAccessScope::Write]
    );
}

#[test]
fn remote_pairing_rejects_wrong_claim_domain() {
    let error = validate_pairing_domain("daemon.example.com", "evil.example.com")
        .expect_err("wrong domain rejected");

    assert!(error.to_string().contains("wrong remote pairing domain"));
}

#[test]
fn remote_pairing_claim_request_rejects_blank_display_name_and_platform() {
    assert!(
        RemotePairingClaimRequest::new_for_tests(
            "daemon.example.com",
            "daemon.example.com",
            "client-1",
            " ",
            "macos",
            Some("203.0.113.10"),
            "audit-claim",
        )
        .is_err(),
        "display name is required for pairing metadata"
    );
    assert!(
        RemotePairingClaimRequest::new_for_tests(
            "daemon.example.com",
            "daemon.example.com",
            "client-1",
            "MacBook Pro",
            "\t",
            Some("203.0.113.10"),
            "audit-claim",
        )
        .is_err(),
        "platform is required for pairing metadata"
    );
}

#[test]
fn remote_pairing_rate_limits_ip_and_code_attempts() {
    let mut limiter = RemotePairingRateLimiter::new_for_tests(2);

    assert!(limiter.record_attempt("203.0.113.10", "code-1").is_ok());
    assert!(limiter.record_attempt("203.0.113.10", "code-1").is_ok());
    assert!(limiter.record_attempt("203.0.113.10", "code-1").is_err());
    assert!(limiter.record_attempt("203.0.113.11", "code-1").is_ok());
}
