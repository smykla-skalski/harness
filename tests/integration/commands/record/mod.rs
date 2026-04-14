use std::fs;
use std::path::{Path, PathBuf};

mod cli_tests;
mod create_validate_tests;
mod env_create_tests;
mod env_kubectl_tests;
mod env_tests;
mod envoy_tests;
mod kumactl_tests;
mod record_tests;
mod workflow_tests;

fn txt_artifact_paths(dir: &Path) -> Vec<PathBuf> {
    fs::read_dir(dir)
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .and_then(|ext| ext.to_str())
                .is_some_and(|ext| ext.eq_ignore_ascii_case("txt"))
        })
        .collect()
}

fn kumactl_binary_dir(repo_root: &Path) -> PathBuf {
    let (os_name, arch) = if cfg!(target_os = "macos") {
        (
            "darwin",
            if cfg!(target_arch = "aarch64") {
                "arm64"
            } else {
                "amd64"
            },
        )
    } else {
        (
            "linux",
            if cfg!(target_arch = "aarch64") {
                "arm64"
            } else {
                "amd64"
            },
        )
    };

    repo_root
        .join("build")
        .join(format!("artifacts-{os_name}-{arch}"))
        .join("kumactl")
}
