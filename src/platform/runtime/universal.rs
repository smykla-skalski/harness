use std::borrow::Cow;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::defaults;
use crate::kernel::topology::ClusterSpec;

use super::access::{ControlPlaneAccess, XdsAccess};

/// Borrowed universal runtime details for a tracked run.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UniversalRuntime<'a> {
    spec: &'a ClusterSpec,
}

impl<'a> UniversalRuntime<'a> {
    pub(crate) fn from_spec(spec: &'a ClusterSpec) -> Self {
        Self { spec }
    }

    /// Resolve a tracked member name to the underlying container name.
    #[must_use]
    pub fn resolve_container_name(self, requested: &'a str) -> Cow<'a, str> {
        self.spec.resolve_container_name(requested)
    }

    /// Docker network for the universal topology.
    ///
    /// # Errors
    /// Returns `CliError` when the network is unavailable.
    pub fn docker_network(self) -> Result<&'a str, CliError> {
        self.spec
            .docker_network
            .as_deref()
            .ok_or_else(|| CliErrorKind::missing_run_context_value("docker_network").into())
    }

    /// Resolve control plane access for the universal runtime.
    ///
    /// # Errors
    /// Returns `CliError` when the control plane endpoint is unavailable.
    pub fn control_plane(self) -> Result<ControlPlaneAccess<'a>, CliError> {
        let Some((ip, port)) = self.spec.primary_api_parts() else {
            return Err(CliErrorKind::missing_run_context_value("cp_api_url").into());
        };
        Ok(ControlPlaneAccess {
            addr: Cow::Owned(format!("http://{ip}:{port}")),
            admin_token: self.spec.admin_token(),
        })
    }

    /// Resolve XDS access for the universal runtime.
    ///
    /// # Errors
    /// Returns `CliError` when the XDS endpoint is unavailable.
    pub fn xds(self) -> Result<XdsAccess<'a>, CliError> {
        let member = self.spec.primary_member();
        let Some(ip) = member.container_ip.as_deref() else {
            return Err(CliErrorKind::missing_run_context_value("container_ip").into());
        };
        Ok(XdsAccess {
            ip,
            port: member.xds_port.unwrap_or(defaults::XDS_PORT),
        })
    }

    /// Resolve the image used for ad-hoc universal service containers.
    ///
    /// # Errors
    /// Returns `CliError` when no image can be determined.
    pub fn service_image(self, explicit: Option<&'a str>) -> Result<Cow<'a, str>, CliError> {
        if let Some(image) = explicit {
            return Ok(Cow::Borrowed(image));
        }
        let Some(cp_image) = self.spec.cp_image.as_deref() else {
            return Err(CliErrorKind::usage_error(
                "service image is required (pass --image or ensure cluster has cp_image set)",
            )
            .into());
        };
        if let Ok(image) = defaults::derive_universal_service_image(cp_image) {
            return Ok(Cow::Owned(image));
        }
        Err(CliErrorKind::usage_error(format!(
            "cannot derive service image from cp_image '{cp_image}' - pass --image explicitly"
        ))
        .into())
    }
}
