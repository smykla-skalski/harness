use std::path::{Path, PathBuf};
#[cfg(feature = "kuma")]
use std::sync::Arc;

use crate::infra::blocks::BlockError;
#[cfg(feature = "kuma")]
use crate::infra::blocks::{ComposeOrchestrator, ContainerRuntime, HttpClient, ProcessExecutor};

#[cfg(test)]
pub mod fake;

pub mod cli;
pub mod compose;
pub mod defaults;
pub mod manifest;
pub mod service;
pub mod token;

/// Kuma-specific control-plane operations and conventions.
///
/// This block is intentionally focused on Kuma domain behavior rather than raw
/// process execution. Callers should depend on this trait instead of hardcoding
/// Kuma constants, image naming conventions, API paths, and token/service
/// bootstrapping logic in command handlers.
pub trait MeshControlPlane: Send + Sync {
    /// Human-readable block name.
    fn name(&self) -> &'static str {
        "kuma"
    }

    /// External binaries that should be denied by guard hooks when invoked
    /// directly instead of through harness workflows.
    fn denied_binaries(&self) -> &'static [&'static str] {
        &["kumactl"]
    }

    /// Return the default Kuma system namespace.
    fn system_namespace(&self) -> &'static str;

    /// Return the default control-plane API port.
    fn api_port(&self) -> u16;

    /// Return the default XDS port.
    fn xds_port(&self) -> u16;

    /// Return the default Envoy admin port used by sidecars.
    fn envoy_admin_port(&self) -> u16;

    /// Return the default universal environment name.
    fn universal_environment(&self) -> &'static str;

    /// Return the default zone mode name.
    fn zone_mode(&self) -> &'static str;

    /// Return the default global mode name.
    fn global_mode(&self) -> &'static str;

    /// Build a fully-qualified control-plane API path from a relative path.
    ///
    /// # Errors
    ///
    /// Returns an error when the provided relative path is empty.
    fn api_path(&self, relative: &str) -> Result<String, BlockError>;

    /// Resolve the resource path used to create a dataplane token.
    ///
    /// # Errors
    ///
    /// Returns an error if the inputs are invalid.
    fn dataplane_token_path(&self, mesh: &str, name: &str) -> Result<String, BlockError>;

    /// Resolve the resource path used to create a zone token.
    ///
    /// # Errors
    ///
    /// Returns an error if the inputs are invalid.
    fn zone_token_path(&self, name: &str) -> Result<String, BlockError>;

    /// Return `true` when the provided image reference looks like a Kuma CP image.
    fn is_cp_image(&self, image: &str) -> bool;

    /// Derive the default universal dataplane image from a control-plane image.
    ///
    /// # Errors
    ///
    /// Returns an error if the image does not look like a supported Kuma CP image.
    fn derive_universal_service_image(&self, cp_image: &str) -> Result<String, BlockError>;

    /// Render a universal dataplane manifest from a logical service description.
    ///
    /// # Errors
    ///
    /// Returns an error when template rendering fails.
    fn render_dataplane(
        &self,
        service_name: &str,
        mesh: &str,
        address: &str,
        port: u16,
        transparent_proxy: bool,
    ) -> Result<String, BlockError>;

    /// Resolve the default location of a locally built `kumactl` binary.
    fn default_kumactl_path(&self, repo_root: &Path) -> PathBuf;

    /// Extract the admin token from a running Kuma control-plane container.
    ///
    /// # Errors
    ///
    /// Returns an error when the token cannot be extracted.
    fn extract_admin_token(&self, cp_container: &str) -> Result<String, BlockError>;
}

/// Default Kuma control-plane implementation backed by existing harness blocks.
///
/// This is currently a thin compatibility layer over the already-existing
/// process/container/HTTP/compose building blocks. It provides a single place
/// for Kuma constants and domain-oriented helpers while the larger extraction
/// proceeds incrementally.
#[cfg(feature = "kuma")]
pub struct KumaControlPlane {
    process: Arc<dyn ProcessExecutor>,
    http: Arc<dyn HttpClient>,
    container_runtime: Arc<dyn ContainerRuntime>,
    compose_orchestrator: Arc<dyn ComposeOrchestrator>,
}

#[cfg(feature = "kuma")]
impl KumaControlPlane {
    #[must_use]
    pub fn new(
        process: Arc<dyn ProcessExecutor>,
        http: Arc<dyn HttpClient>,
        container_runtime: Arc<dyn ContainerRuntime>,
        compose_orchestrator: Arc<dyn ComposeOrchestrator>,
    ) -> Self {
        Self {
            process,
            http,
            container_runtime,
            compose_orchestrator,
        }
    }

    #[must_use]
    pub fn process(&self) -> &Arc<dyn ProcessExecutor> {
        &self.process
    }

    #[must_use]
    pub fn http(&self) -> &Arc<dyn HttpClient> {
        &self.http
    }

    #[must_use]
    pub fn container_runtime(&self) -> &Arc<dyn ContainerRuntime> {
        &self.container_runtime
    }

    #[must_use]
    pub fn compose_orchestrator(&self) -> &Arc<dyn ComposeOrchestrator> {
        &self.compose_orchestrator
    }
}

#[cfg(feature = "kuma")]
impl MeshControlPlane for KumaControlPlane {
    fn system_namespace(&self) -> &'static str {
        defaults::SYSTEM_NAMESPACE
    }

    fn api_port(&self) -> u16 {
        defaults::CP_API_PORT
    }

    fn xds_port(&self) -> u16 {
        defaults::XDS_PORT
    }

    fn envoy_admin_port(&self) -> u16 {
        defaults::ENVOY_ADMIN_PORT
    }

    fn universal_environment(&self) -> &'static str {
        defaults::UNIVERSAL_ENVIRONMENT
    }

    fn zone_mode(&self) -> &'static str {
        defaults::ZONE_MODE
    }

    fn global_mode(&self) -> &'static str {
        defaults::GLOBAL_MODE
    }

    fn api_path(&self, relative: &str) -> Result<String, BlockError> {
        let trimmed = relative.trim();
        if trimmed.is_empty() {
            return Err(BlockError::message(
                "kuma",
                "api_path",
                "relative API path must not be empty",
            ));
        }
        if trimmed.starts_with('/') {
            return Ok(trimmed.to_string());
        }
        Ok(format!("/{trimmed}"))
    }

    fn dataplane_token_path(&self, mesh: &str, name: &str) -> Result<String, BlockError> {
        token::dataplane_token_path(mesh, name)
    }

    fn zone_token_path(&self, name: &str) -> Result<String, BlockError> {
        token::zone_token_path(name)
    }

    fn is_cp_image(&self, image: &str) -> bool {
        defaults::looks_like_kuma_cp_image(image)
    }

    fn derive_universal_service_image(&self, cp_image: &str) -> Result<String, BlockError> {
        defaults::derive_universal_service_image(cp_image)
    }

    fn render_dataplane(
        &self,
        service_name: &str,
        mesh: &str,
        address: &str,
        port: u16,
        transparent_proxy: bool,
    ) -> Result<String, BlockError> {
        service::render_dataplane(service_name, mesh, address, port, transparent_proxy)
    }

    fn default_kumactl_path(&self, repo_root: &Path) -> PathBuf {
        cli::primary_kumactl_dir(repo_root)
    }

    fn extract_admin_token(&self, cp_container: &str) -> Result<String, BlockError> {
        token::extract_admin_token(self.container_runtime.as_ref(), cp_container)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use crate::infra::blocks::{
        FakeComposeOrchestrator, FakeContainerRuntime, FakeHttpClient, FakeProcessExecutor,
    };

    use super::*;

    fn block() -> KumaControlPlane {
        KumaControlPlane::new(
            Arc::new(FakeProcessExecutor::new(vec![])),
            Arc::new(FakeHttpClient::new(vec![])),
            Arc::new(FakeContainerRuntime::new()),
            Arc::new(FakeComposeOrchestrator::new()),
        )
    }

    #[test]
    fn api_path_preserves_leading_slash() {
        let kuma = block();
        assert_eq!(kuma.api_path("/meshes").unwrap(), "/meshes");
    }

    #[test]
    fn api_path_adds_leading_slash() {
        let kuma = block();
        assert_eq!(kuma.api_path("meshes").unwrap(), "/meshes");
    }

    #[test]
    fn denied_binaries_contains_kumactl() {
        let kuma = block();
        assert_eq!(kuma.denied_binaries(), &["kumactl"]);
    }

    #[test]
    fn derives_universal_image_from_cp_image() {
        let kuma = block();
        let derived = kuma
            .derive_universal_service_image("docker.io/kumahq/kuma-cp:2.12.0")
            .unwrap();
        assert_eq!(derived, "docker.io/kumahq/kuma-universal:2.12.0");
    }
}
