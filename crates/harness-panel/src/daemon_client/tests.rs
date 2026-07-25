use super::{ClaimResponse, MintResponse};

/// The panel deserialises only the fields it uses, so a daemon that grows the
/// response must not break it.
#[test]
fn a_claim_answer_carrying_more_than_the_panel_reads_still_parses() {
    let body = r#"{
        "client_id": "panel-1",
        "display_name": "Harness panel",
        "platform": "harness-panel",
        "role": "pairing_broker",
        "scopes": ["pair_mint"],
        "token": "secret-token",
        "token_hint": "sec…",
        "paired_at": "2026-07-25T10:00:00Z"
    }"#;

    let claimed: ClaimResponse = serde_json::from_str(body).expect("a claim answer");

    assert_eq!(claimed.client_id, "panel-1");
    assert_eq!(claimed.token, "secret-token");
    assert_eq!(claimed.role, "pairing_broker");
}

#[test]
fn a_mint_answer_yields_the_link_and_its_lifetime() {
    let body = r#"{
        "pairing_id": "pair-1",
        "role": "operator",
        "scopes": ["read", "write"],
        "created_at": "2026-07-25T10:00:00Z",
        "expires_at": "2026-07-25T10:10:00Z",
        "ttl_seconds": 600,
        "endpoint": "https://harness.example.com",
        "server_spki_sha256": "sha256/AAAA",
        "pairing_url": "harness://pair?payload=abc",
        "subject": {"provider": "github", "subject_id": "4242", "display_name": "Ada"}
    }"#;

    let minted: MintResponse = serde_json::from_str(body).expect("a mint answer");

    assert_eq!(minted.pairing_url, "harness://pair?payload=abc");
    assert_eq!(minted.expires_at, "2026-07-25T10:10:00Z");
    assert_eq!(minted.scopes, vec!["read", "write"]);
}
