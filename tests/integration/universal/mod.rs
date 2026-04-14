use std::fs;
use std::path::Path;

use harness::kernel::topology::{ClusterMember, ClusterMode, ClusterSpec, HelmSetting, Platform};
use harness::run::ValidateArgs;
use harness::run::context::{CommandEnv, RunContext, RunLayout};

use super::helpers::*;

mod cluster_spec_tests;
mod context_tests;
mod platform_tests;
mod validation_tests;

fn assert_universal_cluster_roundtrip(spec: &ClusterSpec) {
    assert_eq!(spec.platform, Platform::Universal);
    assert_eq!(spec.admin_token.as_deref(), Some("admin-token-abc123"));
    assert_eq!(spec.docker_network.as_deref(), Some("harness-test-cp"));
    assert_eq!(spec.store_type.as_deref(), Some("memory"));
    assert_eq!(spec.cp_image.as_deref(), Some("kuma-cp:dev"));
    assert_eq!(
        spec.members[0].container_id.as_deref(),
        Some("container-xyz")
    );
    assert_eq!(spec.members[0].container_ip.as_deref(), Some("172.57.0.3"));
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
    assert_eq!(member.name, "test-cp");
    assert_eq!(member.role, "cp");
    assert!(member.kubeconfig.is_empty());
    assert!(member.zone_name.is_none());
    assert!(member.container_id.is_none());
    assert!(member.container_ip.is_none());
    assert_eq!(member.cp_api_port, Some(5681));
    assert_eq!(member.xds_port, Some(5678));
    assert!(member.kds_port.is_none());
}

fn assert_universal_spec_from_object(spec: &ClusterSpec) {
    assert_eq!(spec.platform, Platform::Universal);
    assert_eq!(spec.docker_network.as_deref(), Some("harness-cp"));
    assert_eq!(spec.store_type.as_deref(), Some("memory"));
    assert_eq!(spec.cp_image.as_deref(), Some("kuma-cp:dev"));
    assert_eq!(spec.admin_token.as_deref(), Some("tok-xyz"));
    assert_eq!(spec.members[0].container_id.as_deref(), Some("abc"));
    assert_eq!(spec.members[0].container_ip.as_deref(), Some("172.57.0.2"));
    assert_eq!(spec.members[0].cp_api_port, Some(5681));
}

fn assert_universal_json_roundtrip(spec: &ClusterSpec) {
    assert_eq!(spec.platform, Platform::Universal);
    assert_eq!(spec.mode, ClusterMode::GlobalZoneUp);
    assert_eq!(spec.admin_token.as_deref(), Some("roundtrip-token"));
    assert_eq!(spec.store_type.as_deref(), Some("memory"));
    assert_eq!(spec.cp_image.as_deref(), Some("kuma-cp:test"));
    assert_eq!(spec.members.len(), 2);
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
