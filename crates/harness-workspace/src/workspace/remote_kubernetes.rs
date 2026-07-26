use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use harness_kernel::errors::CliError;
use harness_kernel::io::read_json_typed;
use harness_kernel::kernel::topology::{ClusterMode, ClusterSpec};

use super::project_context_dir;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteKubernetesInstallState {
    pub mode: ClusterMode,
    pub repo_root: String,
    pub push_prefix: Option<String>,
    pub push_tag: Option<String>,
    pub updated_at_utc: String,
    pub members: Vec<RemoteKubernetesInstallMemberState>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteKubernetesInstallMemberState {
    pub name: String,
    pub source_kubeconfig: String,
    pub source_context: Option<String>,
    pub generated_kubeconfig: String,
    pub namespace: String,
    pub release_name: String,
    pub namespace_created_by_harness: bool,
    pub gateway_api_installed: bool,
    pub published_image_refs: Vec<String>,
}

#[must_use]
pub fn remote_install_state_path_for_spec(spec: &ClusterSpec) -> PathBuf {
    let base = remote_cluster_state_dir(spec);
    base.join("install-state.json")
}

/// # Errors
/// Returns a `CliError` when the state file exists but cannot be read or does not
/// deserialize. A missing file is `Ok(None)`.
pub fn load_remote_install_state_for_spec(
    spec: &ClusterSpec,
) -> Result<Option<RemoteKubernetesInstallState>, CliError> {
    let path = remote_install_state_path_for_spec(spec);
    if !path.exists() {
        return Ok(None);
    }
    read_json_typed(&path).map(Some)
}

fn remote_cluster_state_dir(spec: &ClusterSpec) -> PathBuf {
    remote_install_state_root(Path::new(&spec.repo_root)).join(format!(
        "{}-{}",
        spec.mode.as_str(),
        spec.primary_member().name
    ))
}

fn remote_install_state_root(repo_root: &Path) -> PathBuf {
    project_context_dir(repo_root).join("remote-kubernetes")
}
