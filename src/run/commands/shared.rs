use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

use tracing::warn;

use crate::platform::cluster::Platform;
use crate::core_defs::{harness_data_root, host_platform};
use crate::errors::{CliError, CliErrorKind, cow};
use crate::run::services::RunServices;
use crate::suite_defaults::default_repo_root_for_suite;

/// Resolve the repo root for `init` when not explicitly provided.
///
/// # Errors
/// Returns `CliError` if an explicit path is given but cannot be canonicalized.
pub(crate) fn resolve_init_repo_root(
    raw: Option<&str>,
    suite_dir: &Path,
) -> Result<PathBuf, CliError> {
    if let Some(r) = raw {
        return PathBuf::from(r)
            .canonicalize()
            .map_err(|e| CliErrorKind::io(cow!("canonicalize repo root {r}: {e}")).into());
    }
    if let Some(default) = default_repo_root_for_suite(suite_dir) {
        return Ok(default);
    }
    Ok(env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
}

/// Resolve the run root for `init` when not explicitly provided.
///
/// Priority: explicit `--run-root` flag > `suite_dir/runs` > XDG runs directory.
pub(crate) fn resolve_run_root(raw: Option<&str>, suite_dir: Option<&Path>) -> PathBuf {
    if let Some(explicit) = raw {
        return PathBuf::from(explicit);
    }
    if let Some(directory) = suite_dir {
        return directory.join("runs");
    }
    harness_data_root().join("runs")
}

/// Inject `KUBECONFIG` and `REPO_ROOT` from the persisted run context so
/// kubectl hits the local k3d cluster and kumactl resolves to the
/// worktree build, not whatever is on the default PATH.
///
/// Best-effort: logs warnings on failure instead of propagating errors
/// because record works in detached mode without a full run context.
pub(crate) fn inject_run_env(cmd: &mut Command, run_dir: &Path, cluster: Option<&str>) {
    let services = match RunServices::from_run_dir(run_dir) {
        Ok(s) => s,
        Err(e) => {
            warn!(%e, "failed to load run context");
            return;
        }
    };
    let ctx = services.context();
    let is_universal = ctx
        .cluster
        .as_ref()
        .map(|spec| spec.platform)
        .is_some_and(|platform| platform == Platform::Universal);
    inject_kubeconfig_env(cmd, &services, is_universal, cluster);
    inject_repo_env(cmd, &ctx.metadata.repo_root);
}

fn inject_kubeconfig_env(
    cmd: &mut Command,
    services: &RunServices,
    is_universal: bool,
    cluster: Option<&str>,
) {
    if is_universal {
        return;
    }
    match services.resolve_kubeconfig(None, cluster) {
        Ok(kubeconfig) => {
            cmd.env("KUBECONFIG", kubeconfig.as_ref());
        }
        Err(e) => warn!(%e, "failed to resolve kubeconfig"),
    }
}

fn inject_repo_env(cmd: &mut Command, repo_root: &str) {
    if repo_root.is_empty() {
        return;
    }
    cmd.env("REPO_ROOT", repo_root);
    let (os_name, arch) = host_platform();
    let kumactl_dir = format!("{repo_root}/build/artifacts-{os_name}-{arch}/kumactl");
    if Path::new(&kumactl_dir).is_dir() {
        let current_path = env::var("PATH").unwrap_or_default();
        cmd.env("PATH", format!("{kumactl_dir}:{current_path}"));
    }
}
