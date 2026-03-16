use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};

use crate::commands::resolve_repo_root;
use crate::core_defs::{host_platform, shorten_path};
use crate::errors::{CliError, CliErrorKind};
use crate::exec::run_command;

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

/// Arguments for `harness kumactl`.
#[derive(Debug, Clone, Args)]
pub struct KumactlArgs {
    /// Kumactl subcommand.
    #[command(subcommand)]
    pub cmd: KumactlCommand,
}

fn kumactl_candidates(root: &Path) -> Vec<PathBuf> {
    let (os_name, arch) = host_platform();
    let mut result = vec![
        root.join("build")
            .join(format!("artifacts-{os_name}-{arch}"))
            .join("kumactl")
            .join("kumactl"),
        root.join("build")
            .join(format!("artifacts-{os_name}-{arch}"))
            .join("kumactl"),
    ];
    let alt_arch = if arch == "arm64" { "amd64" } else { "arm64" };
    result.push(
        root.join("build")
            .join(format!("artifacts-{os_name}-{alt_arch}"))
            .join("kumactl")
            .join("kumactl"),
    );
    result.push(root.join("bin").join("kumactl"));
    result
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
    run_command(&["make", "build/kumactl"], Some(root), None, &[0])?;
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
