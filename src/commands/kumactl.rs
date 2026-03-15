use std::path::{Path, PathBuf};

use crate::cli::KumactlCommand;
use crate::errors::{CliError, CliErrorKind};
use crate::exec::run_command;

fn host_platform() -> (&'static str, &'static str) {
    let os_name = if cfg!(target_os = "macos") {
        "darwin"
    } else {
        "linux"
    };
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "amd64"
    };
    (os_name, arch)
}

fn candidates(root: &Path) -> Vec<PathBuf> {
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

fn find_binary(root: &Path) -> Result<PathBuf, CliError> {
    for candidate in candidates(root) {
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
pub fn execute(cmd: &KumactlCommand) -> Result<i32, CliError> {
    match cmd {
        KumactlCommand::Find { repo_root } => {
            let root = super::resolve_repo_root(repo_root.as_deref());
            let binary = find_binary(&root)?;
            println!("{}", binary.display());
            Ok(0)
        }
        KumactlCommand::Build { repo_root } => {
            let root = super::resolve_repo_root(repo_root.as_deref());
            build_kumactl(&root)?;
            let binary = find_binary(&root)?;
            println!("{}", binary.display());
            Ok(0)
        }
    }
}
