use super::*;

#[test]
fn token_kind_maps_to_api_values() {
    assert_eq!(KumaTokenKind::Dataplane.as_api_value(), "dataplane");
    assert_eq!(KumaTokenKind::Zone.as_api_value(), "zone");
    assert_eq!(KumaTokenKind::User.as_api_value(), "user");
}

#[test]
fn request_validation_rejects_empty_fields() {
    let err = KumaTokenRequest::new(KumaTokenKind::Dataplane, "", "default", "24h")
        .validate()
        .expect_err("expected validation error");
    assert!(err.to_string().contains("token name"));
}

#[test]
fn token_api_path_contains_expected_parts() {
    let request = KumaTokenRequest::new(KumaTokenKind::Dataplane, "demo", "default", "24h");
    assert_eq!(
        token_api_path(&request),
        "/tokens/dataplane?name=demo&mesh=default&validFor=24h"
    );
}

#[test]
fn dataplane_token_path_uses_default_validity() {
    let path = dataplane_token_path("default", "demo").expect("expected dataplane path");
    assert_eq!(
        path,
        "/tokens/dataplane?name=demo&mesh=default&validFor=24h"
    );
}

#[test]
fn zone_token_path_uses_default_mesh_and_validity() {
    let path = zone_token_path("zone-1").expect("expected zone path");
    assert_eq!(path, "/tokens/zone?name=zone-1&mesh=default&validFor=24h");
}

#[test]
fn dataplane_token_path_rejects_empty_inputs() {
    assert!(dataplane_token_path("", "demo").is_err());
    assert!(dataplane_token_path("default", "").is_err());
}

#[test]
fn zone_token_path_rejects_empty_name() {
    assert!(zone_token_path("").is_err());
}

#[test]
fn parse_token_response_trims_and_validates() {
    let response = parse_token_response("  abc123  ").expect("expected token");
    assert_eq!(response.token, "abc123");
}

#[test]
fn parse_token_response_rejects_empty_body() {
    let err = parse_token_response("   ").expect_err("expected validation error");
    assert!(err.to_string().contains("token must not be empty"));
}
