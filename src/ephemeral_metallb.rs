use std::path::{Path, PathBuf};

use crate::errors::CliError;

/// State path for ephemeral MetalLB config.
#[must_use]
pub fn state_path(run_dir: &Path) -> PathBuf {
    run_dir.join("ephemeral-metallb-state.json")
}

/// Template path for a cluster.
#[must_use]
pub fn template_path(root: &Path, cluster_name: &str) -> PathBuf {
    root.join(format!("{cluster_name}-metallb.yaml"))
}

/// Ensure MetalLB templates exist for the given clusters.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn ensure_templates(
    _root: &Path,
    _cluster_names: &[&str],
    _run_dir: Option<&Path>,
) -> Result<Vec<PathBuf>, CliError> {
    todo!()
}

/// Cleanup MetalLB templates.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn cleanup_templates(_run_dir: &Path) -> Result<Vec<PathBuf>, CliError> {
    todo!()
}

#[cfg(test)]
mod tests {}
