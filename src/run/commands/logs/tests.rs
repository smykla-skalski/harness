use crate::kernel::topology::{ClusterSpec, Platform};
use crate::platform::runtime::ClusterRuntime;

#[test]
fn resolve_direct_container_single_zone() {
    let spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["test-cp".into()],
        "/r",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    let runtime = ClusterRuntime::from_spec(&spec);
    assert_eq!(runtime.resolve_container_name("test-cp"), "test-cp");
}

#[test]
fn resolve_compose_container_multi_zone() {
    let spec = ClusterSpec::from_mode_with_platform(
        "global-zone-up",
        &["g".into(), "z".into(), "zone-1".into()],
        "/r",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    let runtime = ClusterRuntime::from_spec(&spec);
    assert_eq!(runtime.resolve_container_name("g"), "harness-g-g-1");
}

#[test]
fn resolve_service_container_passthrough() {
    let spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/r",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    let runtime = ClusterRuntime::from_spec(&spec);
    assert_eq!(runtime.resolve_container_name("demo-svc"), "demo-svc");
}
