use std::collections::BTreeMap;
use std::path::Path;

use crate::errors::CliError;
use crate::infra::io::write_json_pretty;
use crate::platform::cluster::Platform;
use crate::platform::kubectl_validate::resolve_kubectl_validate_binary;
use crate::run::SuiteSpec;
use crate::run::context::{
    NodeCheckRecord, NodeCheckSnapshot, PreflightArtifact, ToolCheckRecord, ToolCheckSnapshot,
};
use crate::run::prepared_suite::{PreparedSuiteArtifact, PreparedSuitePlan};
use crate::run::workflow::{
    PreflightStatus, RunnerEvent, RunnerPhase, apply_event, read_runner_state,
};

use super::RunApplication;

impl RunApplication {
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
                .context()
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
