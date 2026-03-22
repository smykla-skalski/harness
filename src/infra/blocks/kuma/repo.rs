use std::path::{Path, PathBuf};

pub const REMOTE_IMAGE_BUILD_TARGET: &str = "images/release";
pub const REMOTE_IMAGE_PUSH_TARGET: &str = "docker/push";
pub const REMOTE_IMAGE_MANIFEST_TARGET: &str = "manifests/json/release";

#[must_use]
pub fn helm_chart_path(repo_root: &Path) -> PathBuf {
    repo_root
        .join("deployments")
        .join("charts")
        .join(chart_directory_name())
}

#[must_use]
pub const fn chart_directory_name() -> &'static str {
    "kuma"
}
