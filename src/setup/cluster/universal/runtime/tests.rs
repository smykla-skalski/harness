use super::*;
use crate::kernel::topology::Platform;

#[test]
fn apply_universal_up_result_persists_runtime_network_name() {
    let mut spec = ClusterSpec::from_mode_with_platform(
        "global-zone-up",
        &["g".into(), "z".into(), "zone-1".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .expect("expected spec");

    apply_universal_up_result(
        &mut spec,
        "kumahq/kuma-cp:0.0.0-preview.vlocal-build",
        "memory",
        UniversalUpResult {
            admin_token: "token".into(),
            docker_network: "harness-g_harness-g".into(),
            members: vec![
                UniversalMemberRuntime {
                    name: "g".into(),
                    container_ip: "172.57.0.2".into(),
                    cp_api_port: defaults::CP_API_PORT,
                    xds_port: None,
                },
                UniversalMemberRuntime {
                    name: "z".into(),
                    container_ip: "172.57.0.3".into(),
                    cp_api_port: 15_681,
                    xds_port: Some(15_678),
                },
            ],
        },
    );

    assert_eq!(spec.docker_network.as_deref(), Some("harness-g_harness-g"));
    assert_eq!(spec.members[0].container_ip.as_deref(), Some("172.57.0.2"));
    assert_eq!(spec.members[1].xds_port, Some(15_678));
}
