use clap::Args;

use crate::app::command_context::{CommandContext, Execute, RunDirArgs, resolve_run_services};
use crate::errors::{CliError, CliErrorKind};

impl Execute for ClusterCheckArgs {
    fn execute(&self, _context: &CommandContext) -> Result<i32, CliError> {
        cluster_check(&self.run_dir)
    }
}

/// Arguments for `harness cluster-check`.
#[derive(Debug, Clone, Args)]
pub struct ClusterCheckArgs {
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Check if cluster containers/networks from the persisted cluster spec are still running.
///
/// Outputs JSON with per-member status. Exit 0 if all healthy, exit 1 if any missing.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn cluster_check(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let services = resolve_run_services(run_dir_args)?;
    let output = services.cluster_health_report()?;
    let pretty = serde_json::to_string_pretty(&output)
        .map_err(|e| CliErrorKind::serialize(format!("cluster-check: {e}")))?;
    println!("{pretty}");

    if output.healthy { Ok(0) } else { Ok(1) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn cluster_check_errors_on_nonexistent_run_dir() {
        let args = RunDirArgs {
            run_dir: Some(PathBuf::from("/tmp/harness-test-nonexistent-xyz")),
            run_id: None,
            run_root: None,
        };
        let err = cluster_check(&args).unwrap_err();
        // Should fail when trying to read run metadata from missing dir
        assert!(
            err.code() == "KSRCLI014" || err.code() == "KSRCLI009",
            "unexpected error code: {}",
            err.code()
        );
    }
}
