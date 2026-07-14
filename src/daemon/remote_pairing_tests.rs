use std::time::{Duration, Instant};

use super::{
    RemotePairingClaimRequest, RemotePairingCode, RemotePairingCodeHash, RemotePairingRateLimiter,
    RemotePairingRecord, RemotePairingStatusRateLimitDecision, RemotePairingStatusRateLimiter,
    validate_pairing_domain,
};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::reviews::ReviewsQueryRequest;

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
    assert!(
        !record
            .code_hash
            .as_storage_value()
            .contains("pairing-secret-value")
    );
    assert!(record.code_hash.verify(code.expose()));
    assert_eq!(
        record.scopes,
        vec![RemoteAccessScope::Read, RemoteAccessScope::Write]
    );
}

#[test]
fn remote_pairing_code_hash_normalizes_surrounding_whitespace() {
    let trimmed_hash =
        RemotePairingCodeHash::from_code("pairing-secret-value").expect("trimmed hash");
    let padded_hash =
        RemotePairingCodeHash::from_code(" \tpairing-secret-value\n").expect("padded hash");

    assert_eq!(
        padded_hash.as_storage_value(),
        trimmed_hash.as_storage_value()
    );
    assert!(trimmed_hash.verify(" \tpairing-secret-value\n"));
}

#[test]
fn remote_pairing_record_normalizes_reviews_query_profile() {
    let query = ReviewsQueryRequest {
        authors: vec![" renovate[bot] ".into(), "renovate[bot]".into()],
        organizations: vec![" smykla-skalski ".into()],
        repositories: vec![
            "smykla-skalski/harness".into(),
            "smykla-skalski/harness".into(),
        ],
        exclude_repositories: vec![" smykla-skalski/archive ".into()],
        force_refresh: true,
        cache_max_age_seconds: 0,
        ..ReviewsQueryRequest::default()
    };

    let record = RemotePairingRecord::new_with_reviews_query_for_tests(
        "pairing-reviews",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        "pairing-secret",
        "2026-07-12T18:00:00Z",
        "2026-07-12T18:10:00Z",
        Some(query),
    )
    .expect("pairing record with reviews query");
    let query = record.reviews_query.expect("reviews query");

    assert_eq!(query.authors, vec!["renovate[bot]"]);
    assert_eq!(query.organizations, vec!["smykla-skalski"]);
    assert_eq!(query.repositories, vec!["smykla-skalski/harness"]);
    assert_eq!(query.exclude_repositories, vec!["smykla-skalski/archive"]);
    assert!(!query.force_refresh);
    assert_eq!(query.cache_max_age_seconds, 1);
}

#[test]
fn remote_pairing_record_rejects_author_only_reviews_query() {
    let query = ReviewsQueryRequest {
        authors: vec!["renovate[bot]".into()],
        ..ReviewsQueryRequest::default()
    };

    let error = RemotePairingRecord::new_with_reviews_query_for_tests(
        "pairing-reviews-invalid",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        "pairing-secret",
        "2026-07-12T18:00:00Z",
        "2026-07-12T18:10:00Z",
        Some(query),
    )
    .expect_err("author-only reviews query must fail");

    assert!(error.to_string().contains("organization or repository"));
}

#[test]
fn remote_pairing_rejects_wrong_claim_domain() {
    let error = validate_pairing_domain("daemon.example.com", "evil.example.com")
        .expect_err("wrong domain rejected");

    assert!(error.to_string().contains("wrong remote pairing domain"));
}

#[test]
fn remote_pairing_claim_request_separates_config_and_claim_domains() {
    let claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "claimed.example.com",
        "client-1",
        "MacBook Pro",
        "macos",
        Some("203.0.113.10"),
        "audit-claim",
    )
    .expect("claim request");

    assert_eq!(claim.expected_domain, "daemon.example.com");
    assert_eq!(claim.claimed_domain, "claimed.example.com");
}

#[test]
fn remote_pairing_claim_request_bounds_request_id() {
    let request_id = "r".repeat(300);
    let claim = RemotePairingClaimRequest::new(
        "daemon.example.com",
        "daemon.example.com",
        "client-1",
        "MacBook Pro",
        "macos",
        Some(request_id.as_str()),
        Some("203.0.113.10"),
        "audit-claim-bounded-request",
    )
    .expect("claim request");

    let stored_request_id = claim.request_id.as_deref().expect("request id");
    assert_eq!(stored_request_id.len(), 256);
    assert!(stored_request_id.ends_with("..."));
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
fn remote_pairing_claim_request_rejects_blank_audit_event_id() {
    assert!(
        RemotePairingClaimRequest::new_for_tests(
            "daemon.example.com",
            "daemon.example.com",
            "client-1",
            "MacBook Pro",
            "macos",
            Some("203.0.113.10"),
            " \t",
        )
        .is_err(),
        "audit event id is required for deterministic pairing audit writes"
    );
}

#[test]
fn remote_pairing_rate_limiter_enforces_independent_ip_budget() {
    let mut limiter = RemotePairingRateLimiter::new_for_tests(2);

    assert!(limiter.record_attempt("203.0.113.10", "code-1").is_ok());
    assert!(limiter.record_attempt("203.0.113.10", "code-2").is_ok());
    assert!(limiter.record_attempt("203.0.113.10", "code-3").is_err());
    assert!(limiter.record_attempt("203.0.113.11", "code-3").is_ok());
}

#[test]
fn remote_pairing_rate_limiter_enforces_independent_code_budget() {
    let mut limiter = RemotePairingRateLimiter::new_for_tests(2);

    assert!(limiter.record_attempt("203.0.113.10", "code-1").is_ok());
    assert!(limiter.record_attempt("203.0.113.11", "code-1").is_ok());
    assert!(limiter.record_attempt("203.0.113.12", "code-1").is_err());
    assert!(limiter.record_attempt("203.0.113.12", "code-2").is_ok());
}

#[test]
fn remote_pairing_rate_limiter_treats_delimiters_as_key_content() {
    let mut limiter = RemotePairingRateLimiter::new_for_tests(1);

    assert!(limiter.record_attempt("addr\0part", "code").is_ok());
    assert!(
        limiter.record_attempt("addr", "part\0code").is_ok(),
        "distinct addresses and code fingerprints must remain independent"
    );
    assert!(limiter.record_attempt("addr\0part", "code").is_err());
}

#[test]
fn remote_pairing_rate_limiter_debug_redacts_code_fingerprints() {
    let mut limiter = RemotePairingRateLimiter::new_for_tests(2);
    limiter
        .record_attempt("203.0.113.10", "raw-secret-code")
        .expect("record attempt");
    let debug = format!("{limiter:?}");

    assert!(!debug.contains("raw-secret-code"));
    assert!(debug.contains("tracked_code_fingerprints"));
}

#[test]
fn remote_pairing_rate_limiter_bounds_tracked_attempts() {
    let mut limiter = RemotePairingRateLimiter::new_bounded_for_tests(1, 2);

    assert!(limiter.record_attempt("203.0.113.1", "code-1").is_ok());
    assert!(limiter.record_attempt("203.0.113.2", "code-2").is_ok());
    assert!(limiter.record_attempt("203.0.113.3", "code-3").is_ok());

    assert_eq!(limiter.tracked_attempts_for_tests(), (2, 2));
    assert!(
        limiter.record_attempt("203.0.113.1", "code-1").is_ok(),
        "oldest entries are evicted when the limiter reaches its bound"
    );
}

#[test]
fn remote_pairing_status_rate_limiter_audits_only_first_denial() {
    let now = Instant::now();
    let mut limiter =
        RemotePairingStatusRateLimiter::new_windowed_for_tests(2, 8, Duration::from_secs(60));

    assert_eq!(
        limiter.record_attempt_at_for_tests("203.0.113.10", "pairing-1", now),
        RemotePairingStatusRateLimitDecision::Allowed
    );
    assert_eq!(
        limiter.record_attempt_at_for_tests("203.0.113.10", "pairing-2", now),
        RemotePairingStatusRateLimitDecision::Allowed
    );
    assert_eq!(
        limiter.record_attempt_at_for_tests("203.0.113.10", "pairing-3", now),
        RemotePairingStatusRateLimitDecision::Denied { audit: true }
    );
    assert_eq!(
        limiter.record_attempt_at_for_tests("203.0.113.10", "pairing-4", now),
        RemotePairingStatusRateLimitDecision::Denied { audit: false }
    );
}

#[test]
fn remote_pairing_status_rate_limiter_enforces_pairing_id_budget() {
    let now = Instant::now();
    let mut limiter =
        RemotePairingStatusRateLimiter::new_windowed_for_tests(2, 8, Duration::from_secs(60));

    assert_eq!(
        limiter.record_attempt_at_for_tests("203.0.113.10", "pairing-1", now),
        RemotePairingStatusRateLimitDecision::Allowed
    );
    assert_eq!(
        limiter.record_attempt_at_for_tests("203.0.113.11", "pairing-1", now),
        RemotePairingStatusRateLimitDecision::Allowed
    );
    assert_eq!(
        limiter.record_attempt_at_for_tests("203.0.113.12", "pairing-1", now),
        RemotePairingStatusRateLimitDecision::Denied { audit: true }
    );
    assert_eq!(
        limiter.record_attempt_at_for_tests("203.0.113.13", "pairing-1", now),
        RemotePairingStatusRateLimitDecision::Denied { audit: false }
    );
}

#[test]
fn remote_pairing_status_rate_limiter_resets_expired_windows() {
    let now = Instant::now();
    let window = Duration::from_secs(60);
    let mut limiter = RemotePairingStatusRateLimiter::new_windowed_for_tests(1, 8, window);

    assert_eq!(
        limiter.record_attempt_at_for_tests("203.0.113.10", "pairing-1", now),
        RemotePairingStatusRateLimitDecision::Allowed
    );
    assert_eq!(
        limiter.record_attempt_at_for_tests("203.0.113.10", "pairing-2", now),
        RemotePairingStatusRateLimitDecision::Denied { audit: true }
    );
    assert_eq!(
        limiter.record_attempt_at_for_tests("203.0.113.10", "pairing-2", now + window,),
        RemotePairingStatusRateLimitDecision::Allowed
    );
}
