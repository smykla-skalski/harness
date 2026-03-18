use std::borrow::Cow;
use std::thread;

use serde::Serialize;

use crate::errors::CliError;
use crate::run::state_capture::UniversalDataplaneCollection;

use super::RunServices;

/// Structured service status row for `harness status`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ServiceStatusRecord {
    pub name: String,
    pub status: String,
}

/// Structured cluster-member row for `harness status`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ClusterMemberStatusRecord<'a> {
    pub name: &'a str,
    pub role: &'a str,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container_ip: Option<&'a str>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp_api_port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub xds_port: Option<u16>,
}

/// Structured result for `harness status`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ClusterStatusReport<'a> {
    pub platform: &'static str,
    pub mode: &'static str,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp_address: Option<Cow<'a, str>>,
    #[serde(default)]
    pub admin_token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub store_type: Option<&'a str>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub docker_network: Option<&'a str>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp_image: Option<&'a str>,
    pub members: Vec<ClusterMemberStatusRecord<'a>>,
    #[serde(default)]
    pub services: Vec<ServiceStatusRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dataplanes: Option<UniversalDataplaneCollection>,
}

impl RunServices {
    /// Build a typed runtime status report for the tracked cluster.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no tracked cluster spec yet.
    ///
    /// # Panics
    /// Panics if an internal query thread panics (should not happen).
    pub fn status_report(&self) -> Result<ClusterStatusReport<'_>, CliError> {
        let runtime = self.cluster_runtime()?;
        let spec = self.cluster_spec()?;
        let (services, dataplanes) = thread::scope(|scope| {
            let t_svc = scope.spawn(|| self.list_service_containers().unwrap_or_default());
            let t_dp = scope.spawn(|| self.query_dataplanes("default").ok());
            (
                t_svc.join().expect("service list thread panicked"),
                t_dp.join().expect("dataplane query thread panicked"),
            )
        });
        Ok(ClusterStatusReport {
            platform: runtime.platform().as_str(),
            mode: spec.mode.as_str(),
            cp_address: self.control_plane_access().ok().map(|access| access.addr),
            admin_token: spec
                .admin_token
                .as_deref()
                .map(mask_token)
                .unwrap_or_default(),
            store_type: spec.store_type.as_deref(),
            docker_network: spec.docker_network.as_deref(),
            cp_image: spec.cp_image.as_deref(),
            members: spec
                .members
                .iter()
                .map(|member| ClusterMemberStatusRecord {
                    name: member.name.as_str(),
                    role: member.role.as_str(),
                    container_ip: member.container_ip.as_deref(),
                    cp_api_port: member.cp_api_port,
                    xds_port: member.xds_port,
                })
                .collect(),
            services,
            dataplanes,
        })
    }
}

fn mask_token(token: &str) -> String {
    if token.len() <= 8 {
        return "****".to_string();
    }
    format!("{}...{}", &token[..4], &token[token.len() - 4..])
}
