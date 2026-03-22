use std::path::{Path, PathBuf};

use fs_err as fs;
use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::kernel::topology::{ClusterMode, ClusterSpec};

use super::project_context_dir;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct RemoteKubernetesInstallState {
    pub mode: ClusterMode,
    pub repo_root: String,
    pub push_prefix: Option<String>,
    pub push_tag: Option<String>,
    pub updated_at_utc: String,
    pub members: Vec<RemoteKubernetesInstallMemberState>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct RemoteKubernetesInstallMemberState {
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

pub(crate) fn remote_install_state_path_for_spec(spec: &ClusterSpec) -> PathBuf {
    let base = remote_cluster_state_dir(spec);
    base.join("install-state.json")
}

pub(crate) fn load_remote_install_state_for_spec(
    spec: &ClusterSpec,
) -> Result<Option<RemoteKubernetesInstallState>, CliError> {
    let path = remote_install_state_path_for_spec(spec);
    if !path.exists() {
        return Ok(None);
    }
    read_json_typed(&path).map(Some)
}

pub(crate) fn persist_remote_install_state(
    spec: &ClusterSpec,
    state: &RemoteKubernetesInstallState,
) -> Result<(), CliError> {
    let path = remote_install_state_path_for_spec(spec);
    write_json_pretty(&path, state)
}

pub(crate) fn cleanup_remote_install_state(
    spec: &ClusterSpec,
    state: &RemoteKubernetesInstallState,
) -> Result<(), CliError> {
    for member in &state.members {
        let path = Path::new(&member.generated_kubeconfig);
        if path.exists() {
            fs::remove_file(path)?;
        }
    }

    let state_path = remote_install_state_path_for_spec(spec);
    if state_path.exists() {
        fs::remove_file(&state_path)?;
    }

    let state_dir = remote_cluster_state_dir(spec);
    if state_dir.exists() {
        let _ = fs::remove_dir(&state_dir);
    }

    Ok(())
}

pub(crate) fn sync_gateway_api_install_state(
    repo_root: &Path,
    kubeconfig: &Path,
    installed: bool,
) -> Result<(), CliError> {
    let root = remote_install_state_root(repo_root);
    if !root.is_dir() {
        return Ok(());
    }

    let target = kubeconfig.display().to_string();
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let state_path = entry.path().join("install-state.json");
        if !state_path.exists() {
            continue;
        }

        let mut state: RemoteKubernetesInstallState = read_json_typed(&state_path)?;
        let mut changed = false;
        for member in &mut state.members {
            if member.generated_kubeconfig == target && member.gateway_api_installed != installed {
                member.gateway_api_installed = installed;
                changed = true;
            }
        }
        if changed {
            write_json_pretty(&state_path, &state)?;
        }
    }

    Ok(())
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
