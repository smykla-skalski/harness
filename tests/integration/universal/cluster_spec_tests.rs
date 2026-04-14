use super::*;

#[test]
fn cluster_spec_universal_fields_roundtrip() {
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

    assert_universal_cluster_roundtrip(&back);
}

#[test]
fn cluster_spec_universal_omits_none_fields_in_json() {
    let spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    let json_value = spec.to_json_dict();
    assert_missing_optional_universal_fields(&json_value);
}

#[test]
fn cluster_spec_kubernetes_omits_docker_fields() {
    let spec =
        ClusterSpec::from_mode("single-up", &["kuma-1".into()], "/repo", vec![], vec![]).unwrap();
    let json_value = spec.to_json_dict();
    assert!(json_value.get("docker_network").is_none());
    assert!(json_value.get("store_type").is_none());
    assert!(json_value.get("cp_image").is_none());
    assert!(json_value.get("admin_token").is_none());
}

#[test]
fn cluster_spec_universal_with_postgres_store() {
    let mut spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    spec.store_type = Some("postgres".into());

    let json = serde_json::to_string(&spec).unwrap();
    let back: ClusterSpec = serde_json::from_str(&json).unwrap();
    assert_eq!(back.store_type.as_deref(), Some("postgres"));
}

#[test]
fn from_mode_universal_topologies() {
    struct Case {
        mode: &'static str,
        args: &'static [&'static str],
        expected_mode: ClusterMode,
        member_count: usize,
        member_roles: &'static [&'static str],
    }

    let cases = [
        Case {
            mode: "single-up",
            args: &["test-cp"],
            expected_mode: ClusterMode::SingleUp,
            member_count: 1,
            member_roles: &["cp"],
        },
        Case {
            mode: "single-down",
            args: &["test-cp"],
            expected_mode: ClusterMode::SingleDown,
            member_count: 1,
            member_roles: &["cp"],
        },
        Case {
            mode: "global-zone-up",
            args: &["global", "zone", "zone-1"],
            expected_mode: ClusterMode::GlobalZoneUp,
            member_count: 2,
            member_roles: &["global-cp", "zone-cp"],
        },
        Case {
            mode: "global-zone-down",
            args: &["global", "zone"],
            expected_mode: ClusterMode::GlobalZoneDown,
            member_count: 2,
            member_roles: &["global-cp", "zone-cp"],
        },
        Case {
            mode: "global-two-zones-up",
            args: &["global", "zone-a", "zone-b", "zone-label-a", "zone-label-b"],
            expected_mode: ClusterMode::GlobalTwoZonesUp,
            member_count: 3,
            member_roles: &["global-cp", "zone-cp", "zone-cp"],
        },
        Case {
            mode: "global-two-zones-down",
            args: &["global", "zone-a", "zone-b"],
            expected_mode: ClusterMode::GlobalTwoZonesDown,
            member_count: 3,
            member_roles: &["global-cp", "zone-cp", "zone-cp"],
        },
    ];

    for c in &cases {
        let args: Vec<String> = c.args.iter().map(ToString::to_string).collect();
        let spec = ClusterSpec::from_mode_with_platform(
            c.mode,
            &args,
            "/repo",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        assert_eq!(spec.platform, Platform::Universal, "mode={}", c.mode);
        assert_eq!(spec.mode, c.expected_mode, "mode={}", c.mode);
        assert_eq!(spec.members.len(), c.member_count, "mode={}", c.mode);
        for (i, role) in c.member_roles.iter().enumerate() {
            assert_eq!(spec.members[i].role, *role, "mode={} member[{i}]", c.mode);
        }
    }
}

#[test]
fn from_mode_universal_docker_network_auto_generated() {
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

#[test]
fn from_mode_universal_rejects_wrong_arg_count() {
    let result = ClusterSpec::from_mode_with_platform(
        "single-up",
        &[],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    );
    assert!(result.is_err());

    let result = ClusterSpec::from_mode_with_platform(
        "global-zone-up",
        &["only-one".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    );
    assert!(result.is_err());
}

#[test]
fn admin_token_returns_none_when_not_set() {
    let spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    assert!(spec.admin_token().is_none());
}

#[test]
fn admin_token_returns_value_when_set() {
    let mut spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    spec.admin_token = Some("secret-token-789".into());
    assert_eq!(spec.admin_token(), Some("secret-token-789"));
}

#[test]
fn admin_token_returns_none_for_kubernetes() {
    let mut spec =
        ClusterSpec::from_mode("single-up", &["kuma-1".into()], "/repo", vec![], vec![]).unwrap();
    spec.admin_token = Some("should-not-happen".into());
    assert_eq!(spec.admin_token(), Some("should-not-happen"));
}

#[test]
fn primary_api_url_returns_none_for_kubernetes() {
    let spec =
        ClusterSpec::from_mode("single-up", &["kuma-1".into()], "/repo", vec![], vec![]).unwrap();
    assert!(spec.primary_api_url().is_none());
}

#[test]
fn primary_api_url_returns_url_for_universal_with_ip() {
    let mut spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    spec.members[0].container_ip = Some("172.57.0.10".into());
    spec.members[0].cp_api_port = Some(5681);
    assert_eq!(
        spec.primary_api_url().as_deref(),
        Some("http://127.0.0.1:5681")
    );
}

#[test]
fn primary_api_url_returns_none_for_universal_without_ip() {
    let spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    assert!(spec.primary_api_url().is_none());
}

#[test]
fn cluster_member_universal_defaults() {
    let member = ClusterMember::universal("test-cp", "cp", None);
    assert_universal_member_defaults(&member);
}

#[test]
fn cluster_member_universal_with_zone_name() {
    let member = ClusterMember::universal("zone-cp", "zone-cp", Some("zone-east"));
    assert_eq!(member.zone_name.as_deref(), Some("zone-east"));
}

#[test]
fn cluster_member_universal_serialization_roundtrip() {
    let mut member = ClusterMember::universal("cp-1", "cp", Some("zone-1"));
    member.container_id = Some("abc123def".into());
    member.container_ip = Some("172.57.0.99".into());
    member.kds_port = Some(5685);

    let json = serde_json::to_string(&member).unwrap();
    let back: ClusterMember = serde_json::from_str(&json).unwrap();
    assert_eq!(back.name, "cp-1");
    assert_eq!(back.container_id.as_deref(), Some("abc123def"));
    assert_eq!(back.container_ip.as_deref(), Some("172.57.0.99"));
    assert_eq!(back.kds_port, Some(5685));
    assert_eq!(back.cp_api_port, Some(5681));
    assert_eq!(back.xds_port, Some(5678));
}

#[test]
fn cluster_spec_from_object_with_universal_fields() {
    let obj = serde_json::json!({
        "mode": "single-up",
        "platform": "universal",
        "mode_args": ["cp"],
        "members": [{
            "name": "cp",
            "role": "cp",
            "kubeconfig": "",
            "cp_api_port": 5681,
            "xds_port": 5678,
            "container_id": "abc",
            "container_ip": "172.57.0.2"
        }],
        "docker_network": "harness-cp",
        "store_type": "memory",
        "cp_image": "kuma-cp:dev",
        "admin_token": "tok-xyz",
        "repo_root": "/repo"
    });
    let spec = ClusterSpec::from_object(&obj).unwrap();
    assert_universal_spec_from_object(&spec);
}

#[test]
fn cluster_spec_from_object_defaults_to_kubernetes() {
    let obj = serde_json::json!({
        "mode": "single-up",
        "mode_args": ["kuma-1"],
        "members": [{
            "name": "kuma-1",
            "role": "primary",
            "kubeconfig": "/tmp/config"
        }],
        "repo_root": "/repo"
    });
    let spec = ClusterSpec::from_object(&obj).unwrap();
    assert_eq!(spec.platform, Platform::Kubernetes);
    assert!(spec.docker_network.is_none());
}

#[test]
fn cluster_spec_to_json_and_back_universal() {
    let mut spec = ClusterSpec::from_mode_with_platform(
        "global-zone-up",
        &["g".into(), "z".into(), "zone-1".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    spec.admin_token = Some("roundtrip-token".into());
    spec.store_type = Some("memory".into());
    spec.cp_image = Some("kuma-cp:test".into());
    spec.members[0].container_ip = Some("172.57.0.100".into());
    spec.members[0].container_id = Some("global-container-id".into());

    let json_value = spec.to_json_dict();
    let back = ClusterSpec::from_object(&json_value).unwrap();

    assert_universal_json_roundtrip(&back);
}
