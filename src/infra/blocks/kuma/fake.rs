use std::path::{Path, PathBuf};
use std::sync::{self, Arc, Mutex};

use crate::infra::blocks::BlockError;

use super::MeshControlPlane;

/// Invocation record for tracking calls to the fake control plane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FakeKumaCall {
    DataplaneTokenPath { mesh: String, name: String },
    ZoneTokenPath { name: String },
    ExtractAdminToken { container: String },
    RenderDataplane { service_name: String, mesh: String },
}

/// Test fake for `MeshControlPlane` with hardcoded defaults and call tracking.
pub struct FakeMeshControlPlane {
    calls: Arc<Mutex<Vec<FakeKumaCall>>>,
}

impl Default for FakeMeshControlPlane {
    fn default() -> Self {
        Self::new()
    }
}

impl FakeMeshControlPlane {
    #[must_use]
    pub fn new() -> Self {
        Self {
            calls: Arc::new(Mutex::new(Vec::new())),
        }
    }

    #[must_use]
    pub fn calls(&self) -> Vec<FakeKumaCall> {
        self.calls
            .lock()
            .unwrap_or_else(sync::PoisonError::into_inner)
            .clone()
    }

    fn record(&self, call: FakeKumaCall) {
        self.calls
            .lock()
            .unwrap_or_else(sync::PoisonError::into_inner)
            .push(call);
    }
}

impl MeshControlPlane for FakeMeshControlPlane {
    fn system_namespace(&self) -> &'static str {
        "kuma-system"
    }

    fn api_port(&self) -> u16 {
        5681
    }

    fn xds_port(&self) -> u16 {
        5678
    }

    fn envoy_admin_port(&self) -> u16 {
        9901
    }

    fn universal_environment(&self) -> &'static str {
        "universal"
    }

    fn zone_mode(&self) -> &'static str {
        "zone"
    }

    fn global_mode(&self) -> &'static str {
        "global"
    }

    fn api_path(&self, relative: &str) -> Result<String, BlockError> {
        let trimmed = relative.trim();
        if trimmed.is_empty() {
            return Err(BlockError::message("kuma", "api_path", "empty path"));
        }
        if trimmed.starts_with('/') {
            return Ok(trimmed.to_string());
        }
        Ok(format!("/{trimmed}"))
    }

    fn dataplane_token_path(&self, mesh: &str, name: &str) -> Result<String, BlockError> {
        self.record(FakeKumaCall::DataplaneTokenPath {
            mesh: mesh.to_string(),
            name: name.to_string(),
        });
        Ok(format!("/tokens/dataplane/{mesh}/{name}"))
    }

    fn zone_token_path(&self, name: &str) -> Result<String, BlockError> {
        self.record(FakeKumaCall::ZoneTokenPath {
            name: name.to_string(),
        });
        Ok(format!("/tokens/zone/{name}"))
    }

    fn is_cp_image(&self, image: &str) -> bool {
        image.contains("kuma-cp")
    }

    fn derive_universal_service_image(&self, cp_image: &str) -> Result<String, BlockError> {
        Ok(cp_image.replace("kuma-cp", "kuma-universal"))
    }

    fn render_dataplane(
        &self,
        service_name: &str,
        mesh: &str,
        _address: &str,
        _port: u16,
        _transparent_proxy: bool,
    ) -> Result<String, BlockError> {
        self.record(FakeKumaCall::RenderDataplane {
            service_name: service_name.to_string(),
            mesh: mesh.to_string(),
        });
        Ok(format!(
            "type: Dataplane\nname: {service_name}\nmesh: {mesh}"
        ))
    }

    fn default_kumactl_path(&self, repo_root: &Path) -> PathBuf {
        repo_root.join("build/artifacts-docker/kumactl")
    }

    fn extract_admin_token(&self, cp_container: &str) -> Result<String, BlockError> {
        self.record(FakeKumaCall::ExtractAdminToken {
            container: cp_container.to_string(),
        });
        Ok("fake-admin-token".to_string())
    }
}

#[cfg(test)]
mod tests {
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

    // -- Contract tests: fake satisfies the same invariants as production --

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
}
