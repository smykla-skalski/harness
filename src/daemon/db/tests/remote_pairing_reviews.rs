use super::*;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_pairing::{
    RemotePairingClaimRequest, RemotePairingCode, RemotePairingRecord,
};
use crate::reviews::ReviewsQueryRequest;

#[test]
fn remote_pairing_reviews_query_survives_persistence_and_claim() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let code = RemotePairingCode::from_value_for_tests("reviews-pairing-secret");
    let query = ReviewsQueryRequest {
        organizations: vec!["smykla-skalski".into()],
        repositories: vec!["smykla-skalski/harness".into()],
        cache_max_age_seconds: 45,
        ..ReviewsQueryRequest::default()
    };
    let record = RemotePairingRecord::new_with_reviews_query_for_tests(
        "pairing-reviews",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        code.expose(),
        "2026-07-12T18:00:00Z",
        "2026-07-12T18:10:00Z",
        Some(query.clone()),
    )
    .expect("pairing record");

    db.create_remote_pairing_code(&record, "audit-create-reviews")
        .expect("persist pairing");
    let metadata: serde_json::Value = db
        .connection()
        .query_row(
            "SELECT metadata_json FROM remote_pairing_codes WHERE pairing_id = 'pairing-reviews'",
            [],
            |row| row.get::<_, String>(0),
        )
        .map(|value| serde_json::from_str(&value).expect("decode metadata"))
        .expect("load metadata");
    assert_eq!(
        metadata["reviews_query"]["repositories"],
        serde_json::json!(["smykla-skalski/harness"])
    );
    assert!(!metadata.to_string().contains(code.expose()));

    let claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "daemon.example.com",
        "reviews-iphone",
        "Bart iPhone",
        "ios",
        Some("203.0.113.44"),
        "audit-claim-reviews",
    )
    .expect("claim request");
    let claimed = db
        .claim_remote_pairing_code(code.expose(), &claim, "2026-07-12T18:01:00Z")
        .expect("claim pairing");

    assert_eq!(claimed.reviews_query, Some(query));
}
