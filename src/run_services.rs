use std::borrow::Cow;
use std::collections::BTreeMap;
use std::path::Path;
#[cfg(test)]
use std::path::PathBuf;

use serde::Serialize;

use crate::audit_log::write_run_status_with_audit;
use crate::cluster::{ClusterSpec, Platform};
use crate::context::{
    NodeCheckRecord, NodeCheckSnapshot, PreflightArtifact, RunContext, RunLayout, RunMetadata,
    ToolCheckRecord, ToolCheckSnapshot,
};
use crate::core_defs::utc_now;
use crate::errors::{CliError, CliErrorKind};
use crate::exec::{self, HttpMethod};
use crate::io::write_json_pretty;
use crate::kubectl_validate::resolve_kubectl_validate_binary;
use crate::prepared_suite::{PreparedSuiteArtifact, PreparedSuitePlan};
use crate::runtime::{ClusterRuntime, ControlPlaneAccess, XdsAccess};
use crate::schema::{RunStatus, SuiteSpec};
use crate::state_capture::{
    DockerContainerSnapshot, KubernetesCaptureSnapshot, KubernetesPodSnapshot,
    StateCaptureSnapshot, UniversalCaptureSnapshot, UniversalDataplaneCollection,
};
use crate::workflow::runner::{
    PreflightStatus, RunnerEvent, RunnerPhase, apply_event, read_runner_state,
};

/// Domain access layer for a tracked run.
#[derive(Debug)]
pub struct RunServices {
    ctx: RunContext,
}

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
    /// Build services from a loaded run context.
    ///
    /// # Errors
    /// Returns `CliError` if the persisted cluster spec cannot be adapted.
    pub fn from_context(ctx: RunContext) -> Result<Self, CliError> {
        Ok(Self { ctx })
    }

    /// Build services from a run directory.
    ///
    /// # Errors
    /// Returns `CliError` if the run context cannot be loaded.
    pub fn from_run_dir(run_dir: &Path) -> Result<Self, CliError> {
        Self::from_context(RunContext::from_run_dir(run_dir)?)
    }

    /// Build services from the current session run pointer.
    ///
    /// # Errors
    /// Returns `CliError` if the pointer or referenced run is invalid.
    pub fn from_current() -> Result<Option<Self>, CliError> {
        RunContext::from_current()?
            .map(Self::from_context)
            .transpose()
    }

    #[must_use]
    pub fn context(&self) -> &RunContext {
        &self.ctx
    }

    #[must_use]
    pub fn into_context(self) -> RunContext {
        self.ctx
    }

    #[must_use]
    pub fn layout(&self) -> &RunLayout {
        &self.ctx.layout
    }

    #[must_use]
    pub fn metadata(&self) -> &RunMetadata {
        &self.ctx.metadata
    }

    #[must_use]
    pub fn status(&self) -> Option<&RunStatus> {
        self.ctx.status.as_ref()
    }

    pub fn status_mut(&mut self) -> Option<&mut RunStatus> {
        self.ctx.status.as_mut()
    }

    /// Return the persisted cluster spec.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no cluster spec yet.
    pub fn cluster_spec(&self) -> Result<&ClusterSpec, CliError> {
        self.ctx
            .cluster
            .as_ref()
            .ok_or_else(|| CliErrorKind::missing_run_context_value("cluster").into())
    }

    /// Return the runtime adapter for the persisted cluster.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no cluster spec yet.
    pub fn cluster_runtime(&self) -> Result<ClusterRuntime<'_>, CliError> {
        self.ctx
            .cluster
            .as_ref()
            .map(ClusterRuntime::from_spec)
            .ok_or_else(|| CliErrorKind::missing_run_context_value("cluster").into())
    }

    /// Resolve a kubeconfig path for Kubernetes runs.
    ///
    /// # Errors
    /// Returns `CliError` when no kubeconfig can be determined.
    pub fn resolve_kubeconfig<'a>(
        &'a self,
        explicit: Option<&'a str>,
        cluster: Option<&str>,
    ) -> Result<Cow<'a, Path>, CliError> {
        self.cluster_runtime()?
            .resolve_kubeconfig(explicit, cluster)
    }

    /// Resolve universal control-plane access.
    ///
    /// # Errors
    /// Returns `CliError` when the run is not universal or the endpoint is incomplete.
    pub fn control_plane_access(&self) -> Result<ControlPlaneAccess<'_>, CliError> {
        self.cluster_runtime()?.control_plane_access()
    }

    /// Resolve universal XDS access.
    ///
    /// # Errors
    /// Returns `CliError` when the run is not universal or the endpoint is incomplete.
    pub fn xds_access(&self) -> Result<XdsAccess<'_>, CliError> {
        self.cluster_runtime()?.xds_access()
    }

    /// Resolve the universal Docker network.
    ///
    /// # Errors
    /// Returns `CliError` when the run is not universal or no network was recorded.
    pub fn docker_network(&self) -> Result<&str, CliError> {
        self.cluster_runtime()?.docker_network()
    }

    #[must_use]
    pub fn resolve_container_name<'a>(&'a self, requested: &'a str) -> Cow<'a, str> {
        self.ctx.cluster.as_ref().map_or_else(
            || Cow::Borrowed(requested),
            |spec| ClusterRuntime::from_spec(spec).resolve_container_name(requested),
        )
    }

    /// Resolve the image used for ad-hoc service containers.
    ///
    /// # Errors
    /// Returns `CliError` when the runtime cannot derive a service image.
    pub fn service_image<'a>(
        &'a self,
        explicit: Option<&'a str>,
    ) -> Result<Cow<'a, str>, CliError> {
        self.cluster_runtime()?.service_image(explicit)
    }

    /// Call the control-plane API and return the raw response body.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no control-plane endpoint or the request fails.
    pub fn call_control_plane_text(
        &self,
        path: &str,
        method: HttpMethod,
        body: Option<&serde_json::Value>,
    ) -> Result<String, CliError> {
        let access = self.control_plane_access()?;
        exec::cp_api_text(access.addr.as_ref(), path, method, body, access.admin_token)
    }

    /// Call the control-plane API and parse the JSON response.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no control-plane endpoint or the request fails.
    pub fn call_control_plane_json(
        &self,
        path: &str,
        method: HttpMethod,
        body: Option<&serde_json::Value>,
    ) -> Result<serde_json::Value, CliError> {
        let access = self.control_plane_access()?;
        exec::cp_api_json(access.addr.as_ref(), path, method, body, access.admin_token)
    }

    #[must_use]
    pub fn service_container_filter(&self) -> String {
        format!("label=io.harness.run-id={}", self.layout().run_id)
    }

    /// List service containers scoped to the current run.
    ///
    /// # Errors
    /// Returns `CliError` on docker invocation failures.
    pub fn list_service_containers(&self) -> Result<Vec<ServiceStatusRecord>, CliError> {
        let result = exec::docker(
            &[
                "ps",
                "--filter",
                &self.service_container_filter(),
                "--format",
                "{{.Names}}\t{{.Status}}",
            ],
            &[0],
        )?;
        Ok(result
            .stdout
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                let mut parts = line.splitn(2, '\t');
                ServiceStatusRecord {
                    name: parts.next().unwrap_or_default().to_string(),
                    status: parts.next().unwrap_or_default().to_string(),
                }
            })
            .collect())
    }

    /// Query the control plane for dataplanes in the target mesh.
    ///
    /// # Errors
    /// Returns `CliError` when the control-plane request fails.
    pub fn query_dataplanes(&self, mesh: &str) -> Result<UniversalDataplaneCollection, CliError> {
        let path = format!("/meshes/{mesh}/dataplanes");
        self.call_control_plane_json(&path, HttpMethod::Get, None)
            .map(UniversalDataplaneCollection::from_api_value)
    }

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
                .iter()
                .map(|member| ClusterMemberHealthRecord {
                    name: member.name.as_str(),
                    role: member.role.as_str(),
                    container: None,
                    running: exec::cluster_exists(&member.name).unwrap_or(false),
                })
                .collect::<Vec<_>>(),
            Platform::Universal => spec
                .members
                .iter()
                .map(|member| {
                    let container = runtime.resolve_container_name(&member.name);
                    ClusterMemberHealthRecord {
                        name: member.name.as_str(),
                        role: member.role.as_str(),
                        running: exec::container_running(&container).unwrap_or(false),
                        container: Some(container),
                    }
                })
                .collect::<Vec<_>>(),
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
                "use 'harness logs <name>' to inspect, or re-run 'harness cluster' to recreate",
            ),
        })
    }

    /// Build a typed runtime status report for the tracked cluster.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no tracked cluster spec yet.
    pub fn status_report(&self) -> Result<ClusterStatusReport<'_>, CliError> {
        let runtime = self.cluster_runtime()?;
        let spec = self.cluster_spec()?;
        let services = self.list_service_containers().unwrap_or_default();
        let dataplanes = self.query_dataplanes("default").ok();
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

    /// Load the suite specification referenced by the run metadata.
    ///
    /// # Errors
    /// Returns `CliError` if the suite markdown cannot be loaded.
    pub fn suite_spec(&self) -> Result<SuiteSpec, CliError> {
        SuiteSpec::from_markdown(Path::new(&self.metadata().suite_path))
    }

    /// Build the preflight materialization plan for this run.
    ///
    /// # Errors
    /// Returns `CliError` if the suite cannot be loaded or parsed.
    pub fn build_preflight_plan(&self, checked_at: &str) -> Result<PreparedSuitePlan, CliError> {
        let suite = self.suite_spec()?;
        PreparedSuitePlan::build(self.layout(), &suite, &self.metadata().profile, checked_at)
    }

    /// Materialize prepared-suite and preflight artifacts to disk.
    ///
    /// # Errors
    /// Returns `CliError` on parse or IO failures.
    pub fn save_preflight_outputs(
        &self,
        checked_at: &str,
    ) -> Result<PreparedSuiteArtifact, CliError> {
        let plan = self.build_preflight_plan(checked_at)?;
        plan.materialize()?;
        plan.artifact.save(&self.layout().prepared_suite_path())?;
        let preflight = self.build_preflight_artifact(checked_at);
        write_json_pretty(&self.layout().preflight_artifact_path(), &preflight)?;
        Ok(plan.artifact)
    }

    /// Capture the current cluster state, persist it, and update the run status.
    ///
    /// # Errors
    /// Returns `CliError` on capture or persistence failures.
    pub fn capture_state(
        &mut self,
        label: &str,
        kubeconfig: Option<&str>,
    ) -> Result<String, CliError> {
        let timestamp = utc_now().replace(':', "");
        let capture_path = self
            .layout()
            .state_dir()
            .join(format!("{label}-{timestamp}.json"));
        let snapshot = self.build_capture_snapshot(kubeconfig)?;
        write_json_pretty(&capture_path, &snapshot)?;

        let rel = self.layout().relative_path(&capture_path).into_owned();
        let run_dir = self.layout().run_dir();
        if let Some(status) = self.ctx.status.as_mut() {
            status.last_state_capture = Some(rel.clone());
            let runner_state = read_runner_state(&run_dir)?;
            write_run_status_with_audit(&run_dir, status, runner_state.as_ref(), None, None)?;
        }
        Ok(rel)
    }

    /// Mark a prepared manifest as applied when it belongs to the tracked run.
    ///
    /// # Errors
    /// Returns `CliError` on prepared-suite load/save failures.
    pub fn mark_manifest_applied(
        &self,
        manifest_path: &Path,
        applied_at: &str,
        step: Option<&str>,
    ) -> Result<(), CliError> {
        let Some(mut artifact) = PreparedSuiteArtifact::load(&self.layout().prepared_suite_path())?
        else {
            return Ok(());
        };
        let rel = self.layout().relative_path(manifest_path).into_owned();
        let Some(manifest) = artifact.manifest_mut_by_prepared_path(&rel) else {
            return Ok(());
        };
        manifest.applied = true;
        manifest.applied_at = Some(applied_at.to_string());
        manifest.applied_path = Some(rel);
        manifest.step = step.map(str::to_string);
        artifact.save(&self.layout().prepared_suite_path())
    }

    /// Advance the runner workflow to completed preflight when applicable.
    ///
    /// # Errors
    /// Returns `CliError` on workflow persistence failures.
    pub fn record_preflight_complete(&self) -> Result<(), CliError> {
        let run_dir = self.layout().run_dir();
        let Some(state) = read_runner_state(&run_dir)? else {
            return Ok(());
        };
        match state.phase() {
            RunnerPhase::Bootstrap => {
                let _ = apply_event(&run_dir, RunnerEvent::PreflightStarted, None, None)?;
                let _ = apply_event(&run_dir, RunnerEvent::PreflightCaptured, None, None)?;
            }
            RunnerPhase::Preflight => {
                if state.preflight_status() != PreflightStatus::Running {
                    let _ = apply_event(&run_dir, RunnerEvent::PreflightStarted, None, None)?;
                }
                let _ = apply_event(&run_dir, RunnerEvent::PreflightCaptured, None, None)?;
            }
            _ => {}
        }
        Ok(())
    }

    fn build_capture_snapshot(
        &self,
        kubeconfig: Option<&str>,
    ) -> Result<StateCaptureSnapshot, CliError> {
        match self.cluster_runtime()?.platform() {
            Platform::Kubernetes => self.capture_kubernetes_snapshot(kubeconfig),
            Platform::Universal => self.capture_universal_snapshot(),
        }
    }

    fn capture_kubernetes_snapshot(
        &self,
        kubeconfig: Option<&str>,
    ) -> Result<StateCaptureSnapshot, CliError> {
        let resolved = self.resolve_kubeconfig(kubeconfig, None)?;
        let result = exec::kubectl(
            Some(resolved.as_ref()),
            &["get", "pods", "--all-namespaces", "-o", "json"],
            &[0],
        )?;
        let value: serde_json::Value = serde_json::from_str(&result.stdout)
            .map_err(|error| CliErrorKind::serialize(format!("capture kubernetes: {error}")))?;
        let pods = value["items"]
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .map(|item| KubernetesPodSnapshot {
                        namespace: item["metadata"]["namespace"]
                            .as_str()
                            .unwrap_or_default()
                            .to_string(),
                        name: item["metadata"]["name"]
                            .as_str()
                            .unwrap_or_default()
                            .to_string(),
                        phase: item["status"]["phase"].as_str().map(str::to_string),
                        ready: item["status"]["containerStatuses"].as_array().is_some_and(
                            |statuses| {
                                !statuses.is_empty()
                                    && statuses
                                        .iter()
                                        .all(|status| status["ready"].as_bool().unwrap_or(false))
                            },
                        ),
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(StateCaptureSnapshot::Kubernetes(
            KubernetesCaptureSnapshot { pods },
        ))
    }

    fn capture_universal_snapshot(&self) -> Result<StateCaptureSnapshot, CliError> {
        let network = self
            .docker_network()
            .ok()
            .map_or_else(|| "harness-default".to_string(), str::to_string);
        let containers = exec::docker(
            &[
                "ps",
                "--filter",
                &format!("network={network}"),
                "--format",
                "{{json .}}",
            ],
            &[0],
        )?;
        let container_rows = containers
            .stdout
            .lines()
            .filter(|line| !line.trim().is_empty())
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .map(|row| DockerContainerSnapshot {
                id: row["ID"].as_str().map(str::to_string),
                image: row["Image"].as_str().map(str::to_string),
                name: row["Names"].as_str().map(str::to_string),
                status: row["Status"].as_str().map(str::to_string),
                networks: row["Networks"].as_str().map(str::to_string),
            })
            .collect();
        let (dataplanes, dataplanes_error) = match self.query_dataplanes("default") {
            Ok(dataplanes) => (dataplanes, None),
            Err(error) => {
                eprintln!("warning: CP API dataplanes query failed: {error}");
                (
                    UniversalDataplaneCollection::default(),
                    Some(error.to_string()),
                )
            }
        };
        Ok(StateCaptureSnapshot::Universal(UniversalCaptureSnapshot {
            containers: container_rows,
            dataplanes,
            dataplanes_error,
        }))
    }

    fn build_preflight_artifact(&self, checked_at: &str) -> PreflightArtifact {
        let binary = resolve_kubectl_validate_binary();
        let tools = ToolCheckSnapshot {
            items: vec![ToolCheckRecord {
                name: "kubectl-validate".to_string(),
                available: binary.is_some(),
                path: binary.as_ref().map(|path| path.display().to_string()),
                detail: binary
                    .is_none()
                    .then_some("binary not installed".to_string()),
            }],
            extra: BTreeMap::default(),
        };
        let nodes = NodeCheckSnapshot {
            items: self
                .ctx
                .cluster
                .as_ref()
                .map(|spec| {
                    spec.members
                        .iter()
                        .map(|member| NodeCheckRecord {
                            name: member.name.clone(),
                            role: Some(member.role.clone()),
                            reachable: Some(
                                spec.platform != Platform::Universal
                                    || member.container_ip.is_some(),
                            ),
                            detail: (spec.platform == Platform::Universal
                                && member.container_ip.is_none())
                            .then_some("container_ip missing".to_string()),
                        })
                        .collect()
                })
                .unwrap_or_default(),
            extra: BTreeMap::default(),
        };

        PreflightArtifact {
            checked_at: checked_at.to_string(),
            prepared_suite_path: Some(
                self.layout()
                    .relative_path(&self.layout().prepared_suite_path())
                    .into_owned(),
            ),
            repo_root: Some(self.metadata().repo_root.clone()),
            tools,
            nodes,
        }
    }
}

fn mask_token(token: &str) -> String {
    if token.len() <= 8 {
        return "****".to_string();
    }
    format!("{}...{}", &token[..4], &token[token.len() - 4..])
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

#[cfg(test)]
mod tests {
    #![allow(clippy::absolute_paths, clippy::cognitive_complexity)]

    use std::fs;

    use super::*;
    use crate::context::RunLayout;
    use crate::io::read_json_typed;
    use crate::schema::{RunCounts, RunStatus, Verdict};
    use crate::workflow::runner::{PreflightStatus, RunnerPhase, initialize_runner_state};

    fn write_suite(dir: &Path) -> PathBuf {
        let suite_dir = dir.join("suite");
        fs::create_dir_all(suite_dir.join("baseline")).unwrap();
        fs::create_dir_all(suite_dir.join("groups")).unwrap();
        fs::write(
            suite_dir.join("baseline").join("namespace.yaml"),
            "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: demo\n",
        )
        .unwrap();
        fs::write(
            suite_dir.join("groups").join("g01.md"),
            r"---
group_id: g01
story: demo
capability: demo
profiles: [single-zone]
preconditions: []
success_criteria: [done]
debug_checks: [logs]
artifacts: []
variant_source: code
helm_values:
  app.replicas: 1
restart_namespaces: [kuma-system]
expected_rejection_orders: [2]
---

## Configure

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: one
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: two
```

## Consume

observe

## Debug

debug
",
        )
        .unwrap();
        let suite_path = suite_dir.join("suite.md");
        fs::write(
            &suite_path,
            r"---
suite_id: demo.suite
feature: demo
scope: unit
profiles: [single-zone]
required_dependencies: []
user_stories: []
variant_decisions: []
coverage_expectations: []
baseline_files: [baseline/namespace.yaml]
groups: [groups/g01.md]
skipped_groups: []
keep_clusters: false
---

# Demo Suite
",
        )
        .unwrap();
        suite_path
    }

    fn write_run(layout: &RunLayout, suite_path: &Path) {
        layout.ensure_dirs().unwrap();
        let suite_dir = suite_path.parent().unwrap();
        let metadata = RunMetadata {
            run_id: layout.run_id.clone(),
            suite_id: "demo.suite".to_string(),
            suite_path: suite_path.display().to_string(),
            suite_dir: suite_dir.display().to_string(),
            profile: "single-zone".to_string(),
            repo_root: suite_dir.display().to_string(),
            keep_clusters: false,
            created_at: "2026-03-16T00:00:00Z".to_string(),
            user_stories: vec![],
            required_dependencies: vec![],
        };
        let status = RunStatus {
            run_id: layout.run_id.clone(),
            suite_id: "demo.suite".to_string(),
            profile: "single-zone".to_string(),
            started_at: "2026-03-16T00:00:00Z".to_string(),
            overall_verdict: Verdict::Pending,
            completed_at: None,
            counts: RunCounts::default(),
            executed_groups: vec![],
            skipped_groups: vec![],
            last_completed_group: None,
            last_state_capture: None,
            last_updated_utc: None,
            next_planned_group: None,
            notes: vec![],
        };
        fs::write(
            layout.metadata_path(),
            serde_json::to_string_pretty(&metadata).unwrap(),
        )
        .unwrap();
        fs::write(
            layout.status_path(),
            serde_json::to_string_pretty(&status).unwrap(),
        )
        .unwrap();
    }

    #[test]
    fn save_preflight_outputs_materializes_artifacts() {
        let dir = tempfile::tempdir().unwrap();
        let suite_path = write_suite(dir.path());
        let layout = RunLayout::from_run_dir(&dir.path().join("runs").join("run-1"));
        write_run(&layout, &suite_path);

        let services = RunServices::from_run_dir(&layout.run_dir()).unwrap();
        let artifact = services
            .save_preflight_outputs("2026-03-16T12:00:00Z")
            .unwrap();

        assert_eq!(artifact.baselines.len(), 1);
        assert_eq!(artifact.groups.len(), 1);
        assert_eq!(artifact.groups[0].manifests.len(), 2);
        assert!(layout.prepared_suite_path().exists());
        assert!(layout.preflight_artifact_path().exists());
        assert!(
            layout
                .run_dir()
                .join("manifests/prepared/baseline/baseline/namespace.yaml")
                .exists()
        );
        assert!(
            layout
                .run_dir()
                .join("manifests/prepared/groups/g01/01.yaml")
                .exists()
        );
        assert!(
            layout
                .run_dir()
                .join("manifests/prepared/groups/g01/02.yaml.validate.txt")
                .exists()
        );

        let preflight: PreflightArtifact =
            read_json_typed(&layout.preflight_artifact_path()).unwrap();
        assert_eq!(preflight.tools.items[0].name, "kubectl-validate");
        assert_eq!(
            preflight.prepared_suite_path.as_deref(),
            Some("prepared-suite.json")
        );
    }

    #[test]
    fn record_preflight_complete_advances_runner_state() {
        let dir = tempfile::tempdir().unwrap();
        let suite_path = write_suite(dir.path());
        let layout = RunLayout::from_run_dir(&dir.path().join("runs").join("run-2"));
        write_run(&layout, &suite_path);
        initialize_runner_state(&layout.run_dir()).unwrap();

        let services = RunServices::from_run_dir(&layout.run_dir()).unwrap();
        services.record_preflight_complete().unwrap();

        let state = crate::workflow::runner::read_runner_state(&layout.run_dir())
            .unwrap()
            .unwrap();
        assert_eq!(state.phase(), RunnerPhase::Execution);
        assert_eq!(state.preflight_status(), PreflightStatus::Complete);
    }

    #[test]
    fn mark_manifest_applied_updates_prepared_suite_artifact() {
        let dir = tempfile::tempdir().unwrap();
        let suite_path = write_suite(dir.path());
        let layout = RunLayout::from_run_dir(&dir.path().join("runs").join("run-3"));
        write_run(&layout, &suite_path);

        let services = RunServices::from_run_dir(&layout.run_dir()).unwrap();
        services
            .save_preflight_outputs("2026-03-16T12:00:00Z")
            .unwrap();

        let manifest_path = layout
            .run_dir()
            .join("manifests/prepared/groups/g01/01.yaml");
        services
            .mark_manifest_applied(&manifest_path, "2026-03-16T12:30:00Z", Some("deploy"))
            .unwrap();

        let artifact = PreparedSuiteArtifact::load(&layout.prepared_suite_path())
            .unwrap()
            .unwrap();
        let manifest = artifact
            .manifest_by_prepared_path("manifests/prepared/groups/g01/01.yaml")
            .unwrap();
        assert!(manifest.applied);
        assert_eq!(manifest.applied_at.as_deref(), Some("2026-03-16T12:30:00Z"));
        assert_eq!(manifest.step.as_deref(), Some("deploy"));
    }

    #[test]
    fn service_container_filter_uses_run_id_label() {
        let dir = tempfile::tempdir().unwrap();
        let suite_path = write_suite(dir.path());
        let layout = RunLayout::from_run_dir(&dir.path().join("runs").join("run-4"));
        write_run(&layout, &suite_path);

        let services = RunServices::from_run_dir(&layout.run_dir()).unwrap();

        assert_eq!(
            services.service_container_filter(),
            "label=io.harness.run-id=run-4"
        );
    }
}
