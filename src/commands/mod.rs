use std::env;
use std::path::PathBuf;

use crate::cluster::Platform;
use crate::context::RunContext;
use crate::errors::{CliError, CliErrorKind};
use crate::resolve::resolve_run_directory;

pub mod args;
pub mod authoring;
pub mod observe;
pub mod run;
pub mod setup;
pub use args::RunDirArgs;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Resolve the repository root from an optional CLI argument, falling back to
/// the current working directory.
pub(crate) fn resolve_repo_root(raw: Option<&str>) -> PathBuf {
    raw.map_or_else(
        || env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        PathBuf::from,
    )
}

/// Resolve a run directory from CLI arguments.
///
/// # Errors
/// Returns `CliError` when the run directory cannot be resolved.
pub(crate) fn resolve_run_dir(args: &RunDirArgs) -> Result<PathBuf, CliError> {
    resolve_run_directory(
        args.run_dir.as_deref(),
        args.run_id.as_deref(),
        args.run_root.as_deref(),
    )
    .map(|r| r.run_dir)
}

/// Resolve a project directory from an optional CLI argument, falling back to
/// the current working directory.
pub(crate) fn resolve_project_dir(raw: Option<&str>) -> PathBuf {
    raw.filter(|s| !s.is_empty()).map_or_else(
        || env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        PathBuf::from,
    )
}

/// Resolve a run directory and load its context in one step.
///
/// # Errors
/// Returns `CliError` when the run directory cannot be resolved or its
/// context cannot be loaded.
pub(crate) fn resolve_run_context(args: &RunDirArgs) -> Result<RunContext, CliError> {
    let run_dir = resolve_run_dir(args)?;
    RunContext::from_run_dir(&run_dir)
}

/// Resolve a kubeconfig path from explicit argument, cluster name, or the
/// primary cluster config in the run context.
///
/// # Errors
/// Returns `CliError` when no kubeconfig can be determined.
pub(crate) fn resolve_kubeconfig(
    ctx: &RunContext,
    explicit: Option<&str>,
    cluster: Option<&str>,
) -> Result<PathBuf, CliError> {
    if let Some(kc) = explicit {
        return Ok(PathBuf::from(kc));
    }
    if let Some(ref spec) = ctx.cluster
        && spec.platform == Platform::Universal
    {
        return Err(CliErrorKind::missing_run_context_value(
            "kubeconfig (universal mode does not use kubeconfig - use CP API instead)",
        )
        .into());
    }
    if let Some(cluster_name) = cluster
        && let Some(ref spec) = ctx.cluster
    {
        let configs = spec.kubeconfigs();
        if let Some(kc) = configs.get(cluster_name) {
            return Ok(PathBuf::from(*kc));
        }
    }
    if let Some(ref spec) = ctx.cluster {
        return Ok(PathBuf::from(spec.primary_kubeconfig()));
    }
    Err(CliErrorKind::missing_run_context_value("kubeconfig").into())
}

/// Resolve CP API URL from run context cluster spec.
///
/// # Errors
/// Returns `CliError` when no CP API URL is available.
pub(crate) fn resolve_cp_addr(ctx: &RunContext) -> Result<String, CliError> {
    if let Some(ref spec) = ctx.cluster
        && let Some(url) = spec.primary_api_url()
    {
        return Ok(url);
    }
    Err(CliErrorKind::missing_run_context_value("cp_api_url").into())
}

/// Resolve admin token from run context cluster spec.
///
/// Returns `None` for Kubernetes mode (no admin token needed).
///
/// # Errors
/// Returns `CliError` when the platform is universal but no admin token is available.
pub(crate) fn resolve_admin_token(ctx: &RunContext) -> Result<Option<String>, CliError> {
    let Some(ref spec) = ctx.cluster else {
        return Ok(None);
    };
    if spec.platform != Platform::Universal {
        return Ok(None);
    }
    spec.admin_token
        .clone()
        .map(Some)
        .ok_or_else(|| CliErrorKind::missing_run_context_value("admin_token").into())
}
