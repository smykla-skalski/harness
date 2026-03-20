use super::*;
use serde_json::json;

#[test]
fn platform_display_roundtrip() {
    for (text, expected) in [
        ("kubernetes", Platform::Kubernetes),
        ("universal", Platform::Universal),
    ] {
        assert_eq!(expected.to_string(), text);
        assert_eq!(text.parse::<Platform>().unwrap(), expected);
    }
}

#[test]
fn platform_k8s_alias() {
    assert_eq!("k8s".parse::<Platform>().unwrap(), Platform::Kubernetes);
}

#[test]
fn cluster_mode_parses_valid_strings() {
    assert_eq!(
        "single-up".parse::<ClusterMode>().unwrap(),
        ClusterMode::SingleUp
    );
    assert_eq!(
        "single-down".parse::<ClusterMode>().unwrap(),
        ClusterMode::SingleDown
    );
    assert_eq!(
        "global-zone-up".parse::<ClusterMode>().unwrap(),
        ClusterMode::GlobalZoneUp
    );
    assert_eq!(
        "global-zone-down".parse::<ClusterMode>().unwrap(),
        ClusterMode::GlobalZoneDown
    );
    assert!("bad-mode".parse::<ClusterMode>().is_err());
}

#[test]
fn from_object_requires_mode() {
    let result = ClusterSpec::from_object(&json!({"repo_root": "/repo"}));
    assert!(result.is_err());
}

#[test]
fn from_object_rejects_legacy_clusters_format() {
    let result = ClusterSpec::from_object(&json!({
        "mode": "global-zone-up",
        "mode_args": ["kuma-global", "kuma-zone", "zone-1"],
        "clusters": ["kuma-global", "kuma-zone"],
        "kubeconfigs": {"kuma-zone": "/tmp/kuma-zone-config"},
        "helm_values": {"controlPlane.mode": "global"},
        "restart_namespaces": ["kuma-system"],
        "repo_root": "/repo"
    }));
    assert!(result.is_err());
}

#[test]
fn current_deploy_round_trip() {
    let spec = ClusterSpec::from_object(&json!({
        "mode": "single-up",
        "mode_args": ["kuma-test"],
        "members": [{"name": "kuma-test", "role": "primary", "kubeconfig": "/tmp/kuma-test-config"}],
        "helm_settings": [{"key": "cp.mode", "value": "standalone"}],
        "restart_namespaces": ["kuma-system"],
        "repo_root": "/repo",
    }))
    .unwrap();

    let payload = spec.to_current_deploy_dict("now");
    let helm_settings = payload["helm_settings"].as_array().unwrap();
    assert_eq!(helm_settings[0]["key"].as_str().unwrap(), "cp.mode");
    assert_eq!(helm_settings[0]["value"].as_str().unwrap(), "standalone");
    assert!(spec.matches_deploy_dict(&payload));
}

#[test]
fn helm_setting_from_cli_arg() {
    let setting = HelmSetting::from_cli_arg("controlPlane.mode=global").unwrap();
    assert_eq!(setting.key, "controlPlane.mode");
    assert_eq!(setting.value, "global");
    assert_eq!(setting.to_cli_arg(), "controlPlane.mode=global");
}

#[test]
fn from_mode_universal_fields_roundtrip() {
    let mut spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["test-cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    spec.admin_token = Some("admin-token-abc123".into());
    spec.docker_network = Some("harness-test-cp".into());
    spec.store_type = Some("memory".into());
    spec.cp_image = Some("kuma-cp:dev".into());
    spec.members[0].container_id = Some("container-xyz".into());
    spec.members[0].container_ip = Some("172.57.0.3".into());

    let json = serde_json::to_string(&spec).unwrap();
    let back: ClusterSpec = serde_json::from_str(&json).unwrap();

    assert_universal_spec_identity(&back);
    assert_universal_spec_runtime(&back);
    assert_universal_spec_member(&back);
}

#[test]
fn from_mode_universal_auto_generates_docker_network() {
    let spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["my-cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    assert_eq!(spec.docker_network.as_deref(), Some("harness-my-cp"));
}

fn assert_universal_spec_identity(spec: &ClusterSpec) {
    assert_eq!(spec.platform, Platform::Universal);
    assert_eq!(spec.admin_token.as_deref(), Some("admin-token-abc123"));
    assert_eq!(spec.docker_network.as_deref(), Some("harness-test-cp"));
}

fn assert_universal_spec_runtime(spec: &ClusterSpec) {
    assert_eq!(spec.store_type.as_deref(), Some("memory"));
    assert_eq!(spec.cp_image.as_deref(), Some("kuma-cp:dev"));
}

fn assert_universal_spec_member(spec: &ClusterSpec) {
    assert_eq!(
        spec.members[0].container_id.as_deref(),
        Some("container-xyz")
    );
    assert_eq!(spec.members[0].container_ip.as_deref(), Some("172.57.0.3"));
}

#[test]
fn cluster_member_universal_defaults() {
    let member = ClusterMember::universal("test-cp", "cp", None);
    assert_eq!(member.cp_api_port, Some(5681));
    assert_eq!(member.xds_port, Some(5678));
    assert!(member.kds_port.is_none());
}

#[test]
fn cluster_spec_roundtrips_via_json_value() {
    let spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    let json = spec.to_json_dict();
    let back = ClusterSpec::from_object(&json).unwrap();
    assert_eq!(back, spec);
}
