use axum::http::HeaderMap;

use super::super::response::extract_request_id;

#[test]
fn extract_request_id_preserves_supplied_header() {
    let mut headers = HeaderMap::new();
    headers.insert(
        "x-request-id",
        "req-123".parse().expect("request id header"),
    );

    assert_eq!(extract_request_id(&headers), "req-123");
}

#[test]
fn extract_request_id_bounds_supplied_header() {
    let mut headers = HeaderMap::new();
    headers.insert(
        "x-request-id",
        "r".repeat(300).parse().expect("long request id header"),
    );

    let request_id = extract_request_id(&headers);

    assert_eq!(request_id.len(), 256);
    assert!(request_id.ends_with("..."));
}

#[test]
fn extract_request_id_generates_fallback_when_header_missing() {
    let first = extract_request_id(&HeaderMap::new());
    let second = extract_request_id(&HeaderMap::new());

    assert!(first.starts_with("daemon-"));
    assert!(second.starts_with("daemon-"));
    assert_ne!(first, second);
}
