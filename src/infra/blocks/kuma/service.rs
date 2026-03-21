use std::borrow::Cow;

use crate::infra::blocks::BlockError;
use crate::platform::runtime::XdsAccess;

use super::defaults;

/// Parameters required to render and start a universal service dataplane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KumaServiceSpec {
    pub name: String,
    pub mesh: String,
    pub address: String,
    pub port: u16,
    pub transparent_proxy: bool,
}

/// Files written into a service container before `kuma-dp` starts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KumaServiceFiles {
    pub token_path: String,
    pub dataplane_path: String,
    pub ca_cert_path: String,
}

/// Resolved startup arguments for `kuma-dp run`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KumaServiceLaunch {
    pub cp_address: String,
    pub args: Vec<String>,
}

/// Kuma-specific helpers for universal service containers.
///
/// This module is intentionally small for now. It provides pure helpers that
/// the future `MeshControlPlane` block can compose without depending on shell
/// execution or filesystem side effects.
pub struct KumaService;

impl KumaService {
    /// Build standard temp-file paths for a service container.
    #[must_use]
    pub fn files_for(service_name: &str) -> KumaServiceFiles {
        KumaServiceFiles {
            token_path: format!("/tmp/{service_name}-token"),
            dataplane_path: format!("/tmp/{service_name}-dp.yaml"),
            ca_cert_path: format!("/tmp/{service_name}-ca.crt"),
        }
    }

    /// Render an embedded dataplane template.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the template cannot be parsed or rendered.
    pub fn render_dataplane_template(
        template_name: &str,
        template_content: &str,
        spec: &KumaServiceSpec,
    ) -> Result<String, BlockError> {
        let env = minijinja::Environment::new();
        let tmpl = env.template_from_str(template_content).map_err(|error| {
            BlockError::new("kuma", &format!("parse template {template_name}"), error)
        })?;

        tmpl.render(serde_json::json!({
            "name": spec.name,
            "mesh": spec.mesh,
            "address": spec.address,
            "port": spec.port,
            "protocol": "http",
        }))
        .map_err(|error| {
            BlockError::new("kuma", &format!("render template {template_name}"), error)
        })
    }

    /// Build `kuma-dp run` arguments for a universal service container.
    #[must_use]
    pub fn launch_for(
        service_name: &str,
        files: &KumaServiceFiles,
        xds: XdsAccess<'_>,
    ) -> KumaServiceLaunch {
        let cp_address = format!("https://{}:{}", xds.ip, xds.port);
        let args = vec![
            "kuma-dp".to_string(),
            "run".to_string(),
            format!("--cp-address={cp_address}"),
            format!("--dataplane-token-file={}", files.token_path),
            format!("--dataplane-file={}", files.dataplane_path),
            format!("--ca-cert-file={}", files.ca_cert_path),
        ];

        let _ = service_name;
        KumaServiceLaunch { cp_address, args }
    }

    /// Derive the readiness URL for a started universal service container.
    #[must_use]
    pub fn readiness_url(address: &str) -> String {
        format!("http://{address}:{}/ready", defaults::DATAPLANE_READY_PORT)
    }

    /// Derive the XDS control-plane URL from resolved access details.
    #[must_use]
    pub fn xds_cp_address(xds: XdsAccess<'_>) -> String {
        format!("https://{}:{}", xds.ip, xds.port)
    }

    /// Derive a service image from a control-plane image.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the control-plane image does not look like a
    /// Kuma CP image.
    pub fn derive_service_image(cp_image: &str) -> Result<Cow<'_, str>, BlockError> {
        if cp_image.contains("kuma-cp") {
            return Ok(Cow::Owned(cp_image.replace("kuma-cp", "kuma-universal")));
        }

        Err(BlockError::message(
            "kuma",
            "derive_service_image",
            format!("cannot derive service image from cp image '{cp_image}'"),
        ))
    }
}

/// Render a universal dataplane manifest using the embedded Harness templates.
///
/// # Errors
///
/// Returns `BlockError` when template parsing or rendering fails.
pub fn render_dataplane(
    service_name: &str,
    mesh: &str,
    address: &str,
    port: u16,
    transparent_proxy: bool,
) -> Result<String, BlockError> {
    let template_name = if transparent_proxy {
        "transparent-proxy.yaml.j2"
    } else {
        "dataplane.yaml.j2"
    };
    let template_content = if transparent_proxy {
        include_str!("../../../../resources/universal/templates/transparent-proxy.yaml.j2")
    } else {
        include_str!("../../../../resources/universal/templates/dataplane.yaml.j2")
    };

    KumaService::render_dataplane_template(
        template_name,
        template_content,
        &KumaServiceSpec {
            name: service_name.to_string(),
            mesh: mesh.to_string(),
            address: address.to_string(),
            port,
            transparent_proxy,
        },
    )
}

#[cfg(test)]
mod tests;
