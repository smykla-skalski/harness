use std::path::PathBuf;

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::run::args::RunDirArgs;

use super::shared::resolve_run_application;

impl Execute for RestartNamespaceArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        restart_namespace(self)
    }
}

/// Arguments for `harness restart-namespace`.
#[derive(Debug, Clone, Args)]
pub struct RestartNamespaceArgs {
    /// Namespace(s) to restart deployments in.
    #[arg(long, required = true)]
    pub namespace: Vec<String>,
    /// Target cluster name (uses its kubeconfig instead of primary).
    #[arg(long)]
    pub cluster: Option<String>,
    /// Use this kubeconfig instead of the tracked run cluster.
    #[arg(long)]
    pub kubeconfig: Option<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Restart deployments in specified namespaces.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn restart_namespace(args: &RestartNamespaceArgs) -> Result<i32, CliError> {
    let run = resolve_run_application(&args.run_dir)?;
    let kubeconfig = if let Some(ref explicit) = args.kubeconfig {
        PathBuf::from(explicit)
    } else {
        run.resolve_kubeconfig(None, args.cluster.as_deref())?
            .into_owned()
    };
    run.kubernetes_runtime()?
        .rollout_restart(Some(&kubeconfig), &args.namespace)?;
    Ok(0)
}
