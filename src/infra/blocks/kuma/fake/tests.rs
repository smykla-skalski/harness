use super::*;

fn assert_string_defaults(fake: &FakeMeshControlPlane) {
    assert_eq!(fake.system_namespace(), "kuma-system");
    assert_eq!(fake.universal_environment(), "universal");
    assert_eq!(fake.zone_mode(), "zone");
    assert_eq!(fake.global_mode(), "global");
}

fn assert_port_defaults(fake: &FakeMeshControlPlane) {
    assert_eq!(fake.api_port(), 5681);
    assert_eq!(fake.xds_port(), 5678);
    assert_eq!(fake.envoy_admin_port(), 9901);
}

#[test]
fn fake_returns_expected_defaults() {
    let fake = FakeMeshControlPlane::new();
    assert_string_defaults(&fake);
    assert_port_defaults(&fake);
}

#[test]
fn fake_tracks_token_calls() {
    let fake = FakeMeshControlPlane::new();
    let _ = fake.dataplane_token_path("default", "dp-1").unwrap();
    let _ = fake.zone_token_path("zone-1").unwrap();

    let calls = fake.calls();
    assert_eq!(calls.len(), 2);
    assert_eq!(
        calls[0],
        FakeKumaCall::DataplaneTokenPath {
            mesh: "default".into(),
            name: "dp-1".into()
        }
    );
    assert_eq!(
        calls[1],
        FakeKumaCall::ZoneTokenPath {
            name: "zone-1".into()
        }
    );
}

#[test]
fn fake_api_path_prepends_slash() {
    let fake = FakeMeshControlPlane::new();
    assert_eq!(fake.api_path("meshes").unwrap(), "/meshes");
    assert_eq!(fake.api_path("/meshes").unwrap(), "/meshes");
}

#[test]
fn fake_derives_universal_image() {
    let fake = FakeMeshControlPlane::new();
    let image = fake
        .derive_universal_service_image("docker.io/kumahq/kuma-cp:2.12.0")
        .unwrap();
    assert_eq!(image, "docker.io/kumahq/kuma-universal:2.12.0");
}

#[test]
fn fake_is_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<FakeMeshControlPlane>();
}

mod contracts {
    use super::*;
    use std::path::Path;

    fn contract_system_namespace_non_empty(kuma: &dyn MeshControlPlane) {
        assert!(!kuma.system_namespace().is_empty());
    }

    fn contract_ports_are_nonzero(kuma: &dyn MeshControlPlane) {
        assert!(kuma.api_port() > 0);
        assert!(kuma.xds_port() > 0);
        assert!(kuma.envoy_admin_port() > 0);
    }

    fn contract_api_path_prepends_slash(kuma: &dyn MeshControlPlane) {
        let result = kuma.api_path("meshes").expect("api_path should succeed");
        assert!(result.starts_with('/'));
    }

    fn contract_api_path_preserves_leading_slash(kuma: &dyn MeshControlPlane) {
        assert_eq!(kuma.api_path("/meshes").unwrap(), "/meshes");
    }

    fn contract_api_path_rejects_empty(kuma: &dyn MeshControlPlane) {
        assert!(kuma.api_path("").is_err());
    }

    fn contract_is_cp_image(kuma: &dyn MeshControlPlane) {
        assert!(kuma.is_cp_image("docker.io/kumahq/kuma-cp:2.12.0"));
    }

    fn contract_derive_universal_image(kuma: &dyn MeshControlPlane) {
        let derived = kuma
            .derive_universal_service_image("docker.io/kumahq/kuma-cp:2.12.0")
            .unwrap();
        assert!(derived.contains("kuma-universal"));
        assert!(derived.contains("2.12.0"));
    }

    fn contract_default_kumactl_path(kuma: &dyn MeshControlPlane) {
        let path = kuma.default_kumactl_path(Path::new("/repo"));
        assert_eq!(path.file_name().expect("should have file name"), "kumactl");
    }

    fn contract_modes_non_empty(kuma: &dyn MeshControlPlane) {
        assert!(!kuma.zone_mode().is_empty());
        assert!(!kuma.global_mode().is_empty());
        assert!(!kuma.universal_environment().is_empty());
    }

    #[test]
    fn fake_satisfies_system_namespace_non_empty() {
        contract_system_namespace_non_empty(&FakeMeshControlPlane::new());
    }

    #[test]
    fn fake_satisfies_ports_are_nonzero() {
        contract_ports_are_nonzero(&FakeMeshControlPlane::new());
    }

    #[test]
    fn fake_satisfies_api_path_prepends_slash() {
        contract_api_path_prepends_slash(&FakeMeshControlPlane::new());
    }

    #[test]
    fn fake_satisfies_api_path_preserves_leading_slash() {
        contract_api_path_preserves_leading_slash(&FakeMeshControlPlane::new());
    }

    #[test]
    fn fake_satisfies_api_path_rejects_empty() {
        contract_api_path_rejects_empty(&FakeMeshControlPlane::new());
    }

    #[test]
    fn fake_satisfies_is_cp_image() {
        contract_is_cp_image(&FakeMeshControlPlane::new());
    }

    #[test]
    fn fake_satisfies_derive_universal_image() {
        contract_derive_universal_image(&FakeMeshControlPlane::new());
    }

    #[test]
    fn fake_satisfies_default_kumactl_path() {
        contract_default_kumactl_path(&FakeMeshControlPlane::new());
    }

    #[test]
    fn fake_satisfies_modes_non_empty() {
        contract_modes_non_empty(&FakeMeshControlPlane::new());
    }
}
