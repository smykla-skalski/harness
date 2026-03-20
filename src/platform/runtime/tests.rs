use std::path::Path;

use crate::kernel::topology::{ClusterMember, ClusterMode, ClusterSpec, HelmSetting, Platform};

use super::{ClusterRuntime, profile_platform};

fn universal_spec() -> ClusterSpec {
    let mut spec = ClusterSpec::from_mode_with_platform(
        "global-zone-up",
        &["g".into(), "z".into(), "zone-1".into()],
        "/repo",
        vec![HelmSetting {
            key: "a".into(),
            value: "b".into(),
        }],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    spec.admin_token = Some("admin-token".into());
    spec.members[0].container_ip = Some("172.57.0.2".into());
    spec
}

#[test]
fn kubernetes_runtime_uses_primary_kubeconfig_by_default() {
    let spec =
        ClusterSpec::from_mode("single-up", &["cp".into()], "/repo", vec![], vec![]).unwrap();
    let runtime = ClusterRuntime::from_spec(&spec);
    let kubeconfig = runtime.resolve_kubeconfig(None, None).unwrap();
    assert_eq!(kubeconfig.as_ref(), Path::new(spec.primary_kubeconfig()));
}

#[test]
fn kubernetes_runtime_resolves_named_cluster() {
    let spec = ClusterSpec {
        mode: spec_mode(),
        platform: Platform::Kubernetes,
        members: vec![
            ClusterMember::named("g", "global", Some("/tmp/g"), None),
            ClusterMember::named("z", "zone", Some("/tmp/z"), Some("zone-1")),
        ],
        mode_args: vec!["g".into(), "z".into(), "zone-1".into()],
        helm_settings: vec![],
        restart_namespaces: vec![],
        repo_root: "/repo".into(),
        docker_network: None,
        store_type: None,
        cp_image: None,
        admin_token: None,
    };
    let runtime = ClusterRuntime::from_spec(&spec);
    let kubeconfig = runtime.resolve_kubeconfig(None, Some("z")).unwrap();
    assert_eq!(kubeconfig.as_ref(), Path::new("/tmp/z"));
}

#[test]
fn universal_runtime_exposes_control_plane_access() {
    let spec = universal_spec();
    let runtime = ClusterRuntime::from_spec(&spec);
    let access = runtime.control_plane_access().unwrap();
    assert_eq!(access.addr.as_ref(), "http://172.57.0.2:5681");
    assert_eq!(access.admin_token, Some("admin-token"));
}

#[test]
fn universal_runtime_resolves_compose_member_container_name() {
    let spec = universal_spec();
    let runtime = ClusterRuntime::from_spec(&spec);
    assert_eq!(
        runtime.resolve_container_name("g").as_ref(),
        "harness-g-g-1"
    );
    assert_eq!(
        runtime.resolve_container_name("demo-svc").as_ref(),
        "demo-svc"
    );
}

#[test]
fn universal_runtime_exposes_xds_access() {
    let spec = universal_spec();
    let runtime = ClusterRuntime::from_spec(&spec);
    let access = runtime.xds_access().unwrap();
    assert_eq!(access.ip, "172.57.0.2");
    assert_eq!(access.port, 5678);
}

#[test]
fn universal_runtime_derives_service_image() {
    let mut spec = universal_spec();
    spec.cp_image = Some("docker.io/kumahq/kuma-cp:2.12.0".into());
    let runtime = ClusterRuntime::from_spec(&spec);
    assert_eq!(
        runtime.service_image(None).unwrap().as_ref(),
        "docker.io/kumahq/kuma-universal:2.12.0"
    );
}

#[test]
fn profile_platform_detects_universal_variants() {
    assert_eq!(profile_platform("universal"), Platform::Universal);
    assert_eq!(profile_platform("universal-global"), Platform::Universal);
    assert_eq!(profile_platform("single-zone"), Platform::Kubernetes);
}

fn spec_mode() -> ClusterMode {
    ClusterMode::GlobalZoneUp
}
