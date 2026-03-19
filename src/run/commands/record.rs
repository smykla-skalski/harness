use std::path::PathBuf;

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::run::application::{RecordCommandRequest, record_command};
use crate::run::args::RunDirArgs;

use super::shared::resolve_run_dir;

impl Execute for RecordArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        record(
            self.repo_root.as_deref(),
            self.phase.as_deref(),
            self.label.as_deref(),
            self.gid.as_deref(),
            self.cluster.as_deref(),
            &self.command,
            &self.run_dir,
        )
    }
}

/// Arguments for `harness record`.
#[derive(Debug, Clone, Args)]
pub struct RecordArgs {
    /// Repo root for local command resolution.
    #[arg(long)]
    pub repo_root: Option<String>,
    /// Optional phase tag for the command artifact name.
    #[arg(long)]
    pub phase: Option<String>,
    /// Optional label tag for the command artifact name.
    #[arg(long)]
    pub label: Option<String>,
    /// Execution-phase group ID for tracked commands.
    #[arg(long)]
    pub gid: Option<String>,
    /// Tracked cluster member name for kubectl commands.
    #[arg(long)]
    pub cluster: Option<String>,
    /// Command to execute; prefix with -- to stop flag parsing.
    #[arg(allow_hyphen_values = true)]
    pub command: Vec<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Record a tracked command and save its output.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn record(
    _repo_root: Option<&str>,
    phase: Option<&str>,
    label: Option<&str>,
    gid: Option<&str>,
    cluster: Option<&str>,
    command_args: &[String],
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = resolve_optional_run_dir(run_dir_args)?;
    let result = record_command(&RecordCommandRequest {
        phase,
        label,
        gid,
        cluster,
        command_args,
        run_dir: run_dir.as_deref(),
    })?;

    if !result.stdout.is_empty() {
        print!("{}", result.stdout);
    }

    Ok(0)
}

fn resolve_optional_run_dir(run_dir_args: &RunDirArgs) -> Result<Option<PathBuf>, CliError> {
    let implicit_lookup = run_dir_args.run_dir.is_none()
        && run_dir_args.run_id.is_none()
        && run_dir_args.run_root.is_none();
    match resolve_run_dir(run_dir_args) {
        Ok(run_dir) => Ok(Some(run_dir)),
        Err(error) if matches!(*error.kind(), CliErrorKind::MissingRunPointer) => Ok(None),
        Err(error) if implicit_lookup && error.code() == "KSRCLI014" => Ok(None),
        Err(error) => Err(error),
    }
}
