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
#[path = "fake/tests.rs"]
mod tests;
