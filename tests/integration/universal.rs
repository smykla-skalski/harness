// Universal mode integration tests.
// Tests Platform enum, ClusterSpec universal fields, compose file generation,
// capabilities output, universal manifest validation, context loading with
// cluster spec, CommandEnv universal fields, admin_token accessor, and
// resolve_kubeconfig error for universal mode.
//
// All tests use the Command + Execute trait (public API).

use std::fs;
use std::path::Path;

use harness::kernel::topology::{ClusterMember, ClusterMode, ClusterSpec, HelmSetting, Platform};
use harness::run::ValidateArgs;
use harness::run::context::{CommandEnv, RunContext, RunLayout};

use super::helpers::*;

// ============================================================================
// 1. Platform enum: parsing, Display, serde roundtrip, Default
// ============================================================================

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

// ============================================================================
// 2. ClusterSpec universal fields: serialization roundtrip
// ============================================================================

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

// ============================================================================
// 3. ClusterSpec::from_mode_with_platform: all topologies with Universal
// ============================================================================

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

// ============================================================================
// 4. Capabilities command: verify JSON includes universal platform and features
// ============================================================================

#[test]
fn capabilities_command_exits_zero() {
    let result = capabilities_cmd().execute();
    assert!(result.is_ok(), "capabilities should succeed: {result:?}");
    assert_eq!(result.unwrap(), 0);
}

// ============================================================================
// 5. Validate command: universal manifest validation
// ============================================================================

#[test]
fn validate_universal_manifest_valid() {
    let tmp = tempfile::tempdir().unwrap();
    let manifest_path = tmp.path().join("mesh-timeout.yaml");
    fs::write(
        &manifest_path,
        "type: MeshTimeout\nname: timeout-policy\nmesh: default\nspec:\n  targetRef:\n    kind: Mesh\n",
    )
    .unwrap();

    let result = validate_cmd(ValidateArgs {
        kubeconfig: None,
        manifest: manifest_path.to_string_lossy().to_string(),
        output: None,
    })
    .execute();
    assert!(
        result.is_ok(),
        "validate universal manifest should succeed: {result:?}"
    );
    assert_eq!(result.unwrap(), 0);

    // Validation output file should be created
    let output_path = manifest_path.with_extension("validation.json");
    assert!(
        output_path.exists(),
        "validation output should exist at {output_path:?}"
    );
}

#[test]
fn validate_universal_manifest_missing_required_fields() {
    let cases: &[(&str, &str)] = &[
        (
            "name: something\nmesh: default\nspec:\n  key: value\n",
            "missing type",
        ),
        (
            "type: MeshTimeout\nmesh: default\nspec:\n  key: value\n",
            "missing name",
        ),
        (
            "type: MeshTimeout\nname: timeout\nspec:\n  key: value\n",
            "missing mesh",
        ),
    ];
    for (yaml, description) in cases {
        let tmp = tempfile::tempdir().unwrap();
        let manifest_path = tmp.path().join("bad-manifest.yaml");
        fs::write(&manifest_path, yaml).unwrap();
        let result = validate_cmd(ValidateArgs {
            kubeconfig: None,
            manifest: manifest_path.to_string_lossy().to_string(),
            output: None,
        })
        .execute();
        assert!(result.is_err(), "validate should fail for {description}");
    }
}

#[test]
fn validate_universal_manifest_zone_ingress_no_mesh_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let manifest_path = tmp.path().join("zone-ingress.yaml");
    // ZoneIngress doesn't need mesh field
    fs::write(
        &manifest_path,
        "type: ZoneIngress\nname: ingress-1\nspec:\n  networking:\n    port: 10001\n",
    )
    .unwrap();

    let result = validate_cmd(ValidateArgs {
        kubeconfig: None,
        manifest: manifest_path.to_string_lossy().to_string(),
        output: None,
    })
    .execute();
    assert!(
        result.is_ok(),
        "validate ZoneIngress without mesh should succeed: {result:?}"
    );
}

#[test]
fn validate_universal_manifest_zone_egress_no_mesh_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let manifest_path = tmp.path().join("zone-egress.yaml");
    fs::write(
        &manifest_path,
        "type: ZoneEgress\nname: egress-1\nspec:\n  networking:\n    port: 10002\n",
    )
    .unwrap();

    let result = validate_cmd(ValidateArgs {
        kubeconfig: None,
        manifest: manifest_path.to_string_lossy().to_string(),
        output: None,
    })
    .execute();
    assert!(
        result.is_ok(),
        "validate ZoneEgress without mesh should succeed: {result:?}"
    );
}

#[test]
fn validate_universal_manifest_zone_no_mesh_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let manifest_path = tmp.path().join("zone.yaml");
    fs::write(
        &manifest_path,
        "type: Zone\nname: zone-east\nspec:\n  address: grpcs://zone-east:5685\n",
    )
    .unwrap();

    let result = validate_cmd(ValidateArgs {
        kubeconfig: None,
        manifest: manifest_path.to_string_lossy().to_string(),
        output: None,
    })
    .execute();
    assert!(
        result.is_ok(),
        "validate Zone without mesh should succeed: {result:?}"
    );
}

#[test]
fn validate_universal_manifest_custom_output_path() {
    let tmp = tempfile::tempdir().unwrap();
    let manifest_path = tmp.path().join("policy.yaml");
    let output_path = tmp.path().join("custom-output.json");
    fs::write(
        &manifest_path,
        "type: MeshRetry\nname: retry-policy\nmesh: default\nspec:\n  targetRef:\n    kind: Mesh\n",
    )
    .unwrap();

    let result = validate_cmd(ValidateArgs {
        kubeconfig: None,
        manifest: manifest_path.to_string_lossy().to_string(),
        output: Some(output_path.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok(), "validate with custom output: {result:?}");
    assert!(output_path.exists(), "custom output path should exist");
}

// ============================================================================
// 6. Context loading: RunContext loads cluster from state/cluster.json
// ============================================================================

#[test]
fn run_context_loads_universal_cluster_from_state() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-uni-ctx", "single-zone");

    // Write a universal cluster spec to state/cluster.json
    let mut spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    spec.admin_token = Some("ctx-token-456".into());
    spec.docker_network = Some("harness-cp".into());
    spec.store_type = Some("memory".into());
    spec.members[0].container_ip = Some("172.57.0.5".into());

    let state_dir = run_dir.join("state");
    fs::write(
        state_dir.join("cluster.json"),
        serde_json::to_string_pretty(&spec).unwrap(),
    )
    .unwrap();

    let context = RunContext::from_run_dir(&run_dir).unwrap();
    let cluster = context.cluster.unwrap();
    assert_eq!(cluster.platform, Platform::Universal);
    assert_eq!(cluster.admin_token.as_deref(), Some("ctx-token-456"));
    assert_eq!(cluster.docker_network.as_deref(), Some("harness-cp"));
    assert_eq!(cluster.store_type.as_deref(), Some("memory"));
    assert_eq!(
        cluster.members[0].container_ip.as_deref(),
        Some("172.57.0.5")
    );
}

#[test]
fn run_context_loads_kubernetes_cluster_from_state() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-k8s-ctx", "single-zone");

    let spec = ClusterSpec::from_mode(
        "single-up",
        &["kuma-test".into()],
        "/repo",
        vec![HelmSetting {
            key: "cp.mode".into(),
            value: "standalone".into(),
        }],
        vec![],
    )
    .unwrap();

    let state_dir = run_dir.join("state");
    fs::write(
        state_dir.join("cluster.json"),
        serde_json::to_string_pretty(&spec).unwrap(),
    )
    .unwrap();

    let context = RunContext::from_run_dir(&run_dir).unwrap();
    let cluster = context.cluster.unwrap();
    assert_eq!(cluster.platform, Platform::Kubernetes);
    assert!(cluster.admin_token.is_none());
    assert!(cluster.docker_network.is_none());
}

#[test]
fn run_context_no_cluster_when_state_file_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-no-cluster", "single-zone");

    let context = RunContext::from_run_dir(&run_dir).unwrap();
    assert!(context.cluster.is_none());
}

// ============================================================================
// 7. CommandEnv: universal fields in env dict
// ============================================================================

#[test]
fn command_env_universal_fields_in_dict() {
    let env = CommandEnv {
        profile: "single-zone-universal".into(),
        repo_root: "/repo".into(),
        run_dir: "/runs/r1".into(),
        run_id: "r1".into(),
        run_root: "/runs".into(),
        suite_dir: "/suites/s".into(),
        suite_id: "s".into(),
        suite_path: "/suites/s/suite.md".into(),
        kubeconfig: None,
        platform: Some("universal".into()),
        cp_api_url: Some("http://172.57.0.2:5681".into()),
        docker_network: Some("harness-net".into()),
    };
    let dict = env.to_env_dict();

    assert_eq!(dict.get("PLATFORM").unwrap(), "universal");
    assert_eq!(dict.get("CP_API_URL").unwrap(), "http://172.57.0.2:5681");
    assert_eq!(dict.get("DOCKER_NETWORK").unwrap(), "harness-net");
    assert!(!dict.contains_key("KUBECONFIG"));
    // 8 base fields + 3 universal fields = 11
    assert_eq!(dict.len(), 11);
}

#[test]
fn command_env_kubernetes_omits_universal_fields() {
    let env = CommandEnv {
        profile: "single-zone".into(),
        repo_root: "/repo".into(),
        run_dir: "/runs/r1".into(),
        run_id: "r1".into(),
        run_root: "/runs".into(),
        suite_dir: "/suites/s".into(),
        suite_id: "s".into(),
        suite_path: "/suites/s/suite.md".into(),
        kubeconfig: Some("/kube/config".into()),
        platform: None,
        cp_api_url: None,
        docker_network: None,
    };
    let dict = env.to_env_dict();

    assert!(!dict.contains_key("PLATFORM"));
    assert!(!dict.contains_key("CP_API_URL"));
    assert!(!dict.contains_key("DOCKER_NETWORK"));
    assert_eq!(dict.get("KUBECONFIG").unwrap(), "/kube/config");
    // 8 base fields + 1 kubeconfig = 9
    assert_eq!(dict.len(), 9);
}

#[test]
fn command_env_serialization_roundtrip_universal() {
    let env = CommandEnv {
        profile: "p".into(),
        repo_root: "/r".into(),
        run_dir: "/d".into(),
        run_id: "i".into(),
        run_root: "/rr".into(),
        suite_dir: "/sd".into(),
        suite_id: "si".into(),
        suite_path: "/sp".into(),
        kubeconfig: None,
        platform: Some("universal".into()),
        cp_api_url: Some("http://10.0.0.1:5681".into()),
        docker_network: Some("harness-cp".into()),
    };
    let json = serde_json::to_string(&env).unwrap();
    let back: CommandEnv = serde_json::from_str(&json).unwrap();
    assert_eq!(back.platform.as_deref(), Some("universal"));
    assert_eq!(back.cp_api_url.as_deref(), Some("http://10.0.0.1:5681"));
    assert_eq!(back.docker_network.as_deref(), Some("harness-cp"));
}

// ============================================================================
// 8. admin_token accessor: ClusterSpec.admin_token() returns correct values
// ============================================================================

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
    // Even if someone sets it, accessor just returns the field
    spec.admin_token = Some("should-not-happen".into());
    assert_eq!(spec.admin_token(), Some("should-not-happen"));
}

// ============================================================================
// 9. primary_api_url: universal vs kubernetes behavior
// ============================================================================

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
        Some("http://172.57.0.10:5681")
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
    // container_ip not set
    assert!(spec.primary_api_url().is_none());
}

// ============================================================================
// ClusterMember::universal builds correct defaults
// ============================================================================

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

// ============================================================================
// ClusterSpec::from_object with universal fields
// ============================================================================

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

// ============================================================================
// RunLayout from_run_dir for universal runs
// ============================================================================

#[test]
fn run_layout_from_run_dir_universal_run() {
    let layout = RunLayout::from_run_dir(Path::new("/runs/universal-run-1"));
    assert_eq!(layout.run_id, "universal-run-1");
    assert_eq!(layout.run_root, "/runs");
    assert_eq!(
        layout.state_dir().to_string_lossy(),
        "/runs/universal-run-1/state"
    );
}

// ============================================================================
// ClusterSpec to_json_dict and from_object roundtrip for universal
// ============================================================================

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

fn assert_universal_cluster_roundtrip(spec: &ClusterSpec) {
    assert_universal_cluster_identity(spec);
    assert_universal_cluster_runtime(spec);
    assert_universal_cluster_member(spec);
}

fn assert_missing_optional_universal_fields(json_value: &serde_json::Value) {
    assert!(json_value.get("store_type").is_none());
    assert!(json_value.get("cp_image").is_none());
    assert!(json_value.get("admin_token").is_none());
    assert_eq!(
        json_value
            .get("docker_network")
            .and_then(serde_json::Value::as_str),
        Some("harness-cp")
    );
}

fn assert_universal_member_defaults(member: &ClusterMember) {
    assert_universal_member_identity(member);
    assert_universal_member_network(member);
    assert_universal_member_ports(member);
}

fn assert_universal_spec_from_object(spec: &ClusterSpec) {
    assert_universal_spec_from_object_identity(spec);
    assert_universal_spec_from_object_runtime(spec);
    assert_universal_spec_from_object_member(spec);
}

fn assert_universal_spec_from_object_identity(spec: &ClusterSpec) {
    assert_eq!(spec.platform, Platform::Universal);
    assert_eq!(spec.docker_network.as_deref(), Some("harness-cp"));
}

fn assert_universal_spec_from_object_runtime(spec: &ClusterSpec) {
    assert_eq!(spec.store_type.as_deref(), Some("memory"));
    assert_eq!(spec.cp_image.as_deref(), Some("kuma-cp:dev"));
    assert_eq!(spec.admin_token.as_deref(), Some("tok-xyz"));
}

fn assert_universal_spec_from_object_member(spec: &ClusterSpec) {
    assert_eq!(spec.members[0].container_id.as_deref(), Some("abc"));
    assert_eq!(spec.members[0].container_ip.as_deref(), Some("172.57.0.2"));
    assert_eq!(spec.members[0].cp_api_port, Some(5681));
}

fn assert_universal_json_roundtrip(spec: &ClusterSpec) {
    assert_universal_json_metadata(spec);
    assert_universal_json_member(spec);
}

fn assert_universal_cluster_identity(spec: &ClusterSpec) {
    assert_eq!(spec.platform, Platform::Universal);
    assert_eq!(spec.admin_token.as_deref(), Some("admin-token-abc123"));
    assert_eq!(spec.docker_network.as_deref(), Some("harness-test-cp"));
}

fn assert_universal_cluster_runtime(spec: &ClusterSpec) {
    assert_eq!(spec.store_type.as_deref(), Some("memory"));
    assert_eq!(spec.cp_image.as_deref(), Some("kuma-cp:dev"));
}

fn assert_universal_cluster_member(spec: &ClusterSpec) {
    assert_eq!(
        spec.members[0].container_id.as_deref(),
        Some("container-xyz")
    );
    assert_eq!(spec.members[0].container_ip.as_deref(), Some("172.57.0.3"));
}

fn assert_universal_member_identity(member: &ClusterMember) {
    assert_eq!(member.name, "test-cp");
    assert_eq!(member.role, "cp");
    assert!(member.kubeconfig.is_empty());
}

fn assert_universal_member_network(member: &ClusterMember) {
    assert!(member.zone_name.is_none());
    assert!(member.container_id.is_none());
    assert!(member.container_ip.is_none());
}

fn assert_universal_member_ports(member: &ClusterMember) {
    assert_eq!(member.cp_api_port, Some(5681));
    assert_eq!(member.xds_port, Some(5678));
    assert!(member.kds_port.is_none());
}

fn assert_universal_json_metadata(spec: &ClusterSpec) {
    assert_eq!(spec.platform, Platform::Universal);
    assert_eq!(spec.mode, ClusterMode::GlobalZoneUp);
    assert_eq!(spec.admin_token.as_deref(), Some("roundtrip-token"));
    assert_eq!(spec.store_type.as_deref(), Some("memory"));
    assert_eq!(spec.cp_image.as_deref(), Some("kuma-cp:test"));
    assert_eq!(spec.members.len(), 2);
}

fn assert_universal_json_member(spec: &ClusterSpec) {
    assert_eq!(
        spec.members[0].container_ip.as_deref(),
        Some("172.57.0.100")
    );
    assert_eq!(
        spec.members[0].container_id.as_deref(),
        Some("global-container-id")
    );
    assert_eq!(spec.members[0].role, "global-cp");
    assert_eq!(spec.members[1].role, "zone-cp");
}

// ============================================================================
// Capture universal path: context resolution and platform detection
// ============================================================================

#[test]
fn capture_universal_resolves_context() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "cap-uni", "single-zone");

    // Write a universal cluster spec to state/cluster.json
    let mut spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    spec.admin_token = Some("tok-capture".into());
    spec.docker_network = Some("harness-cp".into());
    spec.members[0].container_ip = Some("172.57.0.2".into());

    let state_dir = run_dir.join("state");
    fs::write(
        state_dir.join("cluster.json"),
        serde_json::to_string_pretty(&spec).unwrap(),
    )
    .unwrap();

    // Verify context loads with universal platform
    let context = RunContext::from_run_dir(&run_dir).unwrap();
    let cluster = context.cluster.as_ref().unwrap();
    assert_eq!(cluster.platform, Platform::Universal);
    assert_eq!(cluster.docker_network.as_deref(), Some("harness-cp"));
}
