use std::fs;
use std::io::{self, Read as _};
use std::path::{Path, PathBuf};

use clap::Args;

use tracing::warn;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::manifest::resource_api_path;
use crate::infra::exec;
use crate::infra::exec::kubectl;
use crate::infra::io::{ensure_dir, validate_safe_segment, write_text};
use crate::kernel::topology::Platform;
use crate::platform::runtime::ClusterRuntime;
use crate::run::args::RunDirArgs;
use crate::run::resolve::resolve_manifest_path;
use crate::workspace::{shorten_path, utc_now};

use super::kumactl::find_kumactl_binary;
use super::shared::resolve_run_application;

impl Execute for ApplyArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        apply(
            self.kubeconfig.as_deref(),
            self.cluster.as_deref(),
            &self.manifest,
            self.step.as_deref(),
            &self.run_dir,
        )
    }
}
/// Arguments for `harness apply`.
#[derive(Debug, Clone, Args)]
pub struct ApplyArgs {
    /// Use this kubeconfig instead of the tracked run cluster.
    #[arg(long)]
    pub kubeconfig: Option<String>,
    /// Target cluster name (uses its kubeconfig instead of primary).
    #[arg(long)]
    pub cluster: Option<String>,
    /// Manifest file or directory path. Repeat to preserve explicit batch order.
    #[arg(long, required = true)]
    pub manifest: Vec<String>,
    /// Optional step label for manifest index notes.
    #[arg(long)]
    pub step: Option<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Apply manifests to the cluster.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn apply(
    kubeconfig: Option<&str>,
    cluster_arg: Option<&str>,
    manifests: &[String],
    step: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run = resolve_run_application(run_dir_args)?;
    let run_dir = run.layout().run_dir();
    let runtime = run.cluster_runtime()?;

    for manifest_raw in manifests {
        let manifest = if manifest_raw == "-" {
            materialize_stdin(&run_dir, step)?
        } else {
            resolve_manifest_path(manifest_raw, Some(&run_dir))?
        };
        let manifest_str = manifest.to_string_lossy().into_owned();

        match runtime.platform() {
            Platform::Kubernetes => {
                let kc = run.resolve_kubeconfig(kubeconfig, cluster_arg)?;
                kubectl(Some(kc.as_ref()), &["apply", "-f", &manifest_str], &[0])?;
            }
            Platform::Universal => {
                apply_universal(&run.metadata().repo_root, &runtime, &manifest_str)?;
            }
        }

        let applied_at = utc_now();
        let rel = run.layout().relative_path(&manifest);
        let notes = step.map_or_else(String::new, |s| format!("{s}: "));
        run.layout()
            .append_manifest_index(&applied_at, rel.as_ref(), "-", "PASS", &notes)?;
        run.mark_manifest_applied(&manifest, &applied_at, step)?;
        println!("{}", shorten_path(&manifest));
    }
    Ok(0)
}

/// Read stdin and write to a temporary manifest file in the run's manifests dir.
fn materialize_stdin(run_dir: &Path, step: Option<&str>) -> Result<PathBuf, CliError> {
    let mut content = String::new();
    io::stdin()
        .read_to_string(&mut content)
        .map_err(|e| CliErrorKind::io(format!("read stdin: {e}")))?;
    if content.trim().is_empty() {
        return Err(CliErrorKind::usage_error("stdin manifest is empty").into());
    }
    let manifests_dir = run_dir.join("manifests");
    ensure_dir(&manifests_dir)?;
    let name = step.unwrap_or("stdin");
    validate_safe_segment(name)?;
    let path = manifests_dir.join(format!("{name}.yaml"));
    write_text(&path, &content)?;
    Ok(path)
}

fn apply_universal(
    repo_root: &str,
    runtime: &ClusterRuntime<'_>,
    manifest: &str,
) -> Result<(), CliError> {
    let access = runtime.control_plane_access()?;

    // Try REST API first - parse manifest YAML and PUT to CP
    let content = fs::read_to_string(manifest)
        .map_err(|e| CliErrorKind::io(format!("read manifest {manifest}: {e}")))?;
    let resource: serde_json::Value = serde_yml::from_str(&content)
        .map_err(|e| CliErrorKind::io(format!("parse manifest {manifest}: {e}")))?;

    if let (Some(resource_type), Some(name)) =
        (resource["type"].as_str(), resource["name"].as_str())
    {
        let mesh = resource["mesh"].as_str();
        let path = resource_api_path(resource_type, name, mesh)
            .map_err(|error| CliErrorKind::usage_error(error.to_string()))?;
        match exec::cp_api_json(
            access.addr.as_ref(),
            &path,
            exec::HttpMethod::Put,
            Some(&resource),
            access.admin_token,
        ) {
            Ok(_) => return Ok(()),
            Err(e) => warn!(%e, "REST API failed, falling back to kumactl"),
        }
    }

    // Fallback to kumactl
    let root = PathBuf::from(repo_root);
    let binary = find_kumactl_binary(&root)?;
    exec::kumactl_run(&binary, &access.addr, &["apply", "-f", manifest], &[0])?;
    Ok(())
}

#[cfg(test)]
#[path = "apply/tests.rs"]
mod tests;
