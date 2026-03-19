use std::thread;

use rayon::prelude::*;

use crate::errors::CliError;
use crate::infra::exec;
use crate::platform::cluster::Platform;
use crate::run::services::{
    ClusterHealthReport, ClusterMemberHealthRecord, ClusterMemberStatusRecord, ClusterStatusReport,
};

use super::RunApplication;

impl RunApplication {
    /// Check current cluster member health.
    ///
    /// # Errors
    /// Returns `CliError` on runtime inspection failures.
    pub fn cluster_health_report(&self) -> Result<ClusterHealthReport<'_>, CliError> {
        let runtime = self.cluster_runtime()?;
        let spec = self.cluster_spec()?;
        let mut members = match runtime.platform() {
            Platform::Kubernetes => spec
                .members
                .par_iter()
                .map(|member| ClusterMemberHealthRecord {
                    name: member.name.as_str(),
                    role: member.role.as_str(),
                    container: None,
                    running: exec::cluster_exists(&member.name).unwrap_or(false),
                })
                .collect::<Vec<_>>(),
            Platform::Universal => {
                spec.members
                    .par_iter()
                    .map(|member| {
                        let container = runtime.resolve_container_name(&member.name);
                        ClusterMemberHealthRecord {
                            name: member.name.as_str(),
                            role: member.role.as_str(),
                            running: self.services.docker_if_available().is_some_and(|docker| {
                                docker.is_running(&container).unwrap_or(false)
                            }),
                            container: Some(container),
                        }
                    })
                    .collect::<Vec<_>>()
            }
        };
        if runtime.platform() == Platform::Universal
            && let Ok(network) = runtime.docker_network()
        {
            members.push(ClusterMemberHealthRecord {
                name: network,
                role: "network",
                container: None,
                running: docker_network_exists(network),
            });
        }
        let healthy = members.iter().all(|member| member.running);
        Ok(ClusterHealthReport {
            healthy,
            members,
            hint: (!healthy).then_some(
                "use 'harness run logs <name>' to inspect, or re-run 'harness setup kuma cluster' to recreate",
            ),
        })
    }

    /// Build the current cluster status report.
    ///
    /// # Errors
    /// Returns `CliError` on runtime inspection failures.
    ///
    /// # Panics
    /// Panics if an internal query thread panics (should not happen).
    pub fn status_report(&self) -> Result<ClusterStatusReport<'_>, CliError> {
        let runtime = self.cluster_runtime()?;
        let spec = self.cluster_spec()?;
        let (services, dataplanes) = thread::scope(|scope| {
            let list_services = scope.spawn(|| self.list_service_containers().unwrap_or_default());
            let query_dataplanes = scope.spawn(|| self.query_dataplanes("default").ok());
            (
                list_services.join().expect("service list thread panicked"),
                query_dataplanes
                    .join()
                    .expect("dataplane query thread panicked"),
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

fn docker_network_exists(network: &str) -> bool {
    exec::docker(
        &[
            "network",
            "ls",
            "--filter",
            &format!("name=^{network}$"),
            "--format",
            "{{.Name}}",
        ],
        &[0],
    )
    .ok()
    .is_some_and(|result| result.stdout.trim() == network)
}

fn mask_token(token: &str) -> String {
    if token.len() <= 8 {
        return "****".to_string();
    }
    format!("{}...{}", &token[..4], &token[token.len() - 4..])
}
