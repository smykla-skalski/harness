use std::borrow::Cow;

use rayon::prelude::*;
use serde::Serialize;

use crate::platform::cluster::Platform;
use crate::errors::CliError;
use crate::infra::exec;

use super::RunServices;

/// Runtime health for a tracked cluster member or backing network.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ClusterMemberHealthRecord<'a> {
    pub name: &'a str,
    pub role: &'a str,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container: Option<Cow<'a, str>>,
    pub running: bool,
}

/// Structured result for `harness cluster-check`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ClusterHealthReport<'a> {
    pub healthy: bool,
    pub members: Vec<ClusterMemberHealthRecord<'a>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<&'static str>,
}

impl RunServices {
    /// Build a typed runtime health report for the tracked cluster.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no tracked cluster spec yet.
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
                            running: self.blocks.docker.as_ref().is_some_and(|docker| {
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
                "use 'harness run logs <name>' to inspect, or re-run 'harness setup cluster' to recreate",
            ),
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
