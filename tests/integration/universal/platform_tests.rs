use super::*;

#[test]
fn platform_parses_kubernetes() {
    let platform: Platform = "kubernetes".parse().unwrap();
    assert_eq!(platform, Platform::Kubernetes);
}

#[test]
fn platform_parses_k8s_alias() {
    let platform: Platform = "k8s".parse().unwrap();
    assert_eq!(platform, Platform::Kubernetes);
}

#[test]
fn platform_parses_universal() {
    let platform: Platform = "universal".parse().unwrap();
    assert_eq!(platform, Platform::Universal);
}

#[test]
fn platform_rejects_invalid_string() {
    let result = "docker".parse::<Platform>();
    assert!(result.is_err());
    let error = result.unwrap_err();
    assert!(
        error.contains("unsupported platform"),
        "error should mention unsupported: {error}"
    );
}

#[test]
fn platform_display_kubernetes() {
    assert_eq!(Platform::Kubernetes.to_string(), "kubernetes");
}

#[test]
fn platform_display_universal() {
    assert_eq!(Platform::Universal.to_string(), "universal");
}

#[test]
fn platform_display_roundtrip() {
    for platform in [Platform::Kubernetes, Platform::Universal] {
        let text = platform.to_string();
        let parsed: Platform = text.parse().unwrap();
        assert_eq!(parsed, platform);
    }
}

#[test]
fn platform_serde_roundtrip_kubernetes() {
    let json = serde_json::to_string(&Platform::Kubernetes).unwrap();
    assert_eq!(json, "\"kubernetes\"");
    let back: Platform = serde_json::from_str(&json).unwrap();
    assert_eq!(back, Platform::Kubernetes);
}

#[test]
fn platform_serde_roundtrip_universal() {
    let json = serde_json::to_string(&Platform::Universal).unwrap();
    assert_eq!(json, "\"universal\"");
    let back: Platform = serde_json::from_str(&json).unwrap();
    assert_eq!(back, Platform::Universal);
}

#[test]
fn platform_default_is_kubernetes() {
    assert_eq!(Platform::default(), Platform::Kubernetes);
}

#[test]
fn capabilities_command_exits_zero() {
    let result = capabilities_cmd().execute();
    assert!(result.is_ok(), "capabilities should succeed: {result:?}");
    assert_eq!(result.unwrap(), 0);
}
