use std::path::{Path, PathBuf};

use crate::infra::environment::host_platform;

/// Default build target used to produce a local `kumactl`.
pub const BUILD_TARGET: &str = "build/kumactl";

/// Primary directory containing host-platform `kumactl` artifacts.
#[must_use]
pub fn primary_kumactl_dir(repo_root: &Path) -> PathBuf {
    let (os_name, arch) = host_platform();
    repo_root
        .join("build")
        .join(format!("artifacts-{os_name}-{arch}"))
        .join("kumactl")
}

/// Candidate paths for a locally-built `kumactl` binary.
#[must_use]
pub fn kumactl_candidates(root: &Path) -> Vec<PathBuf> {
    let (os_name, arch) = host_platform();
    let mut result = vec![
        primary_kumactl_dir(root).join("kumactl"),
        primary_kumactl_dir(root),
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
