use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};

use crate::app::command_context::{CommandContext, Execute, resolve_repo_root};
use crate::workspace::shorten_path;
use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::cli::{BUILD_TARGET, kumactl_candidates};
use crate::infra::exec::run_command;

impl Execute for KumactlArgs {
    fn execute(&self, _context: &CommandContext) -> Result<i32, CliError> {
        kumactl(&self.cmd)
    }
}

/// Find or build kumactl.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum KumactlCommand {
    /// Find an existing kumactl binary.
    Find {
        /// Repo root to search for built kumactl artifacts.
        #[arg(long)]
        repo_root: Option<String>,
    },
    /// Build kumactl from source.
    Build {
        /// Repo root to build and locate kumactl.
        #[arg(long)]
        repo_root: Option<String>,
    },
}

/// Arguments for `harness run kuma cli`.
#[derive(Debug, Clone, Args)]
pub struct KumactlArgs {
    /// Kumactl subcommand.
    #[command(subcommand)]
    pub cmd: KumactlCommand,
}

pub(crate) fn find_kumactl_binary(root: &Path) -> Result<PathBuf, CliError> {
    for candidate in kumactl_candidates(root) {
        if candidate.is_file() {
            return Ok(candidate);
        }
    }
    Err(CliErrorKind::KumactlNotFound.into())
}

fn build_kumactl(root: &Path) -> Result<(), CliError> {
    run_command(&["make", BUILD_TARGET], Some(root), None, &[0])?;
    Ok(())
}

/// Find or build kumactl.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn kumactl(cmd: &KumactlCommand) -> Result<i32, CliError> {
    match cmd {
        KumactlCommand::Find { repo_root } => {
            let root = resolve_repo_root(repo_root.as_deref());
            let binary = find_kumactl_binary(&root)?;
            println!("{}", shorten_path(&binary));
            Ok(0)
        }
        KumactlCommand::Build { repo_root } => {
            let root = resolve_repo_root(repo_root.as_deref());
            build_kumactl(&root)?;
            let binary = find_kumactl_binary(&root)?;
            println!("{}", shorten_path(&binary));
            Ok(0)
        }
    }
}
