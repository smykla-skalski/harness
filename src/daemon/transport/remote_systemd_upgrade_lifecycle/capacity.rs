use std::fs::Metadata;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

use fs_err as fs;

use crate::errors::CliError;

use super::files::{
    combine_errors, io_error, regular_file_metadata, remove_file_if_exists, sync_directory,
};
use super::model::{
    BINARY_FILE, ENVIRONMENT_FILE, GenerationManifest, RemoteSystemdOperationPlan, STATE_DIRECTORY,
    UNIT_FILE,
};

mod bytes;
mod debris;
mod inodes;
mod measure;

use bytes::{reserve_file, reserve_is_sufficient};
#[cfg(test)]
pub(crate) use inodes::reserve_inode_capacity_with_available_for_tests;
use inodes::{inode_reserve_is_sufficient, release_inode_capacity, reserve_inode_capacity};
use measure::{TreeCapacity, tree_copy_capacity};

const STATE_HEADROOM: u64 = 16 * 1024 * 1024;
const BINARY_HEADROOM: u64 = 1024 * 1024;
const STATE_INODE_HEADROOM: u64 = 64;
const BINARY_INODE_HEADROOM: u64 = 8;

#[derive(Debug, Clone, Copy)]
pub(super) struct RestoreCapacity {
    state_bytes: u64,
    binary_bytes: u64,
    state_inodes: u64,
    binary_inodes: u64,
}

pub(super) fn required_restore_capacity(
    plan: &RemoteSystemdOperationPlan,
    state_paths: &[&Path],
    binary_paths: &[&Path],
) -> Result<RestoreCapacity, CliError> {
    validate_restore_filesystems(plan)?;
    let state_capacity = state_paths
        .iter()
        .try_fold(TreeCapacity::default(), |total, path| {
            total.checked_add(tree_copy_capacity(path)?, "state restore")
        })?
        .with_headroom(STATE_HEADROOM, STATE_INODE_HEADROOM, "state restore")?;
    let file_capacity = binary_paths
        .iter()
        .try_fold(TreeCapacity::default(), |total, path| {
            let metadata = regular_file_metadata(path)
                .map_err(|error| io_error(format!("size restore binary: {error}")))?;
            total.checked_add(
                TreeCapacity {
                    bytes: metadata.len(),
                    inodes: 1,
                },
                "file restore",
            )
        })?;
    let file_capacity =
        file_capacity.with_headroom(BINARY_HEADROOM, BINARY_INODE_HEADROOM, "file restore")?;
    if plan.state_path.parent().is_none() || plan.binary_path.parent().is_none() {
        return Err(io_error("systemd restore reserve path has no parent"));
    }
    Ok(RestoreCapacity {
        state_bytes: state_capacity.bytes,
        binary_bytes: file_capacity.bytes,
        state_inodes: state_capacity.inodes,
        binary_inodes: file_capacity.inodes,
    })
}

pub(super) fn validate_restore_filesystems(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    require_atomic_state_store(plan)?;
    require_shared_file_restore_filesystem(plan)
}

pub(super) fn reconcile_restore_debris(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    debris::reconcile_restore_debris(plan)
}

fn require_shared_file_restore_filesystem(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    let binary_parent = plan
        .binary_path
        .parent()
        .ok_or_else(|| io_error("installed binary path has no parent"))?;
    let expected_device = directory_metadata(binary_parent, "installed binary parent")?.dev();
    for (label, path) in [
        ("systemd unit parent", &plan.unit_path),
        ("systemd environment parent", &plan.environment_path),
    ] {
        let parent = path
            .parent()
            .ok_or_else(|| io_error(format!("{label} has no parent")))?;
        if directory_metadata(parent, label)?.dev() != expected_device {
            return Err(io_error(format!(
                "systemd binary, unit, and environment must share a filesystem for atomic rollback: {} and {}",
                binary_parent.display(),
                parent.display()
            )));
        }
    }
    Ok(())
}

pub(super) fn reserve_restore_capacity(
    plan: &RemoteSystemdOperationPlan,
    capacity: RestoreCapacity,
) -> Result<(), CliError> {
    reconcile_restore_debris(plan)?;
    reserve_capacity_scope(
        &plan.state_reserve_path(),
        &plan.state_inode_reserve_path(),
        capacity.state_bytes,
        capacity.state_inodes,
    )?;
    if let Err(error) = reserve_capacity_scope(
        &plan.binary_reserve_path()?,
        &plan.binary_inode_reserve_path()?,
        capacity.binary_bytes,
        capacity.binary_inodes,
    ) {
        let cleanup = release_restore_capacity(plan);
        return Err(combine_errors(
            "reserve binary restore capacity",
            &error,
            cleanup.err(),
        ));
    }
    Ok(())
}

pub(super) fn reserve_generation_restore_capacity(
    plan: &RemoteSystemdOperationPlan,
    generation_path: &Path,
    manifest: &GenerationManifest,
) -> Result<(), CliError> {
    reserve_generations_restore_capacity(plan, &[(generation_path, manifest)])
}

pub(super) fn reserve_bidirectional_restore_capacity(
    plan: &RemoteSystemdOperationPlan,
    first_path: &Path,
    first_manifest: &GenerationManifest,
    second_path: &Path,
    second_manifest: &GenerationManifest,
) -> Result<(), CliError> {
    reserve_generations_restore_capacity(
        plan,
        &[(first_path, first_manifest), (second_path, second_manifest)],
    )
}

fn reserve_generations_restore_capacity(
    plan: &RemoteSystemdOperationPlan,
    generations: &[(&Path, &GenerationManifest)],
) -> Result<(), CliError> {
    let state_sources = generations
        .iter()
        .map(|(path, _)| path.join(STATE_DIRECTORY))
        .collect::<Vec<_>>();
    let mut file_sources = Vec::new();
    for (path, manifest) in generations {
        file_sources.push(path.join(BINARY_FILE));
        if manifest.unit_metadata.is_some() {
            file_sources.push(path.join(UNIT_FILE));
        }
        if manifest.environment_metadata.is_some() {
            file_sources.push(path.join(ENVIRONMENT_FILE));
        }
    }
    let state_source_refs = state_sources
        .iter()
        .map(PathBuf::as_path)
        .collect::<Vec<_>>();
    let file_source_refs = file_sources
        .iter()
        .map(PathBuf::as_path)
        .collect::<Vec<_>>();
    let capacity = required_restore_capacity(plan, &state_source_refs, &file_source_refs)?;
    reserve_restore_capacity(plan, capacity)
}

#[cfg(test)]
pub(crate) fn required_restore_capacity_for_tests(
    plan: &RemoteSystemdOperationPlan,
    state_paths: &[&Path],
    file_paths: &[&Path],
) -> Result<(u64, u64), CliError> {
    required_restore_capacity(plan, state_paths, file_paths)
        .map(|capacity| (capacity.state_bytes, capacity.binary_bytes))
}

#[cfg(test)]
pub(crate) fn required_restore_inodes_for_tests(
    plan: &RemoteSystemdOperationPlan,
    state_paths: &[&Path],
    file_paths: &[&Path],
) -> Result<(u64, u64), CliError> {
    required_restore_capacity(plan, state_paths, file_paths)
        .map(|capacity| (capacity.state_inodes, capacity.binary_inodes))
}

#[cfg(test)]
pub(crate) fn reserve_bidirectional_restore_capacity_for_tests(
    plan: &RemoteSystemdOperationPlan,
    first_path: &Path,
    second_path: &Path,
) -> Result<(), CliError> {
    let first_manifest = super::generation::load_manifest(first_path)?;
    let second_manifest = super::generation::load_manifest(second_path)?;
    reserve_bidirectional_restore_capacity(
        plan,
        first_path,
        &first_manifest,
        second_path,
        &second_manifest,
    )
}

#[cfg(test)]
pub(crate) fn release_restore_capacity_for_tests(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    release_restore_capacity(plan)
}

pub(super) fn ensure_restore_capacity(
    plan: &RemoteSystemdOperationPlan,
    capacity: RestoreCapacity,
    state_needed: bool,
    binary_needed: bool,
) -> Result<(), CliError> {
    let state_bytes_path = plan.state_reserve_path();
    let state_inodes_path = plan.state_inode_reserve_path();
    if state_needed
        && !capacity_scope_is_sufficient(
            &state_bytes_path,
            &state_inodes_path,
            capacity.state_bytes,
            capacity.state_inodes,
        )?
    {
        release_state_restore_capacity(plan)?;
        reserve_capacity_scope(
            &state_bytes_path,
            &state_inodes_path,
            capacity.state_bytes,
            capacity.state_inodes,
        )?;
    }
    let binary_bytes_path = plan.binary_reserve_path()?;
    let binary_inodes_path = plan.binary_inode_reserve_path()?;
    if binary_needed
        && !capacity_scope_is_sufficient(
            &binary_bytes_path,
            &binary_inodes_path,
            capacity.binary_bytes,
            capacity.binary_inodes,
        )?
    {
        release_binary_restore_capacity(plan)?;
        reserve_capacity_scope(
            &binary_bytes_path,
            &binary_inodes_path,
            capacity.binary_bytes,
            capacity.binary_inodes,
        )?;
    }
    Ok(())
}

fn capacity_scope_is_sufficient(
    byte_path: &Path,
    inode_path: &Path,
    required_bytes: u64,
    required_inodes: u64,
) -> Result<bool, CliError> {
    Ok(reserve_is_sufficient(byte_path, required_bytes)?
        && inode_reserve_is_sufficient(inode_path, required_inodes)?)
}

pub(super) fn release_restore_capacity(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    let state = release_state_restore_capacity(plan);
    let binary = release_binary_restore_capacity(plan);
    match state {
        Ok(()) => binary,
        Err(error) => Err(combine_errors(
            "release systemd restore capacity",
            &error,
            binary.err(),
        )),
    }
}

pub(super) fn release_state_restore_capacity(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    release_capacity_scope(&plan.state_reserve_path(), &plan.state_inode_reserve_path())
}

pub(super) fn release_binary_restore_capacity(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    release_capacity_scope(
        &plan.binary_reserve_path()?,
        &plan.binary_inode_reserve_path()?,
    )
}

fn release_capacity_scope(byte_path: &Path, inode_path: &Path) -> Result<(), CliError> {
    let bytes = remove_file_if_exists(byte_path);
    let inodes = release_inode_capacity(inode_path);
    let parent = byte_path.parent().map_or_else(
        || Err(io_error("restore reserve path has no parent")),
        sync_directory,
    );
    bytes
        .and(inodes)
        .and(parent)
        .map_err(|error| io_error(format!("release systemd restore reserve: {error}")))
}

#[cfg(test)]
pub(crate) fn reconcile_restore_debris_for_tests(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    reconcile_restore_debris(plan)
}

fn reserve_capacity_scope(
    byte_path: &Path,
    inode_path: &Path,
    bytes: u64,
    inodes: u64,
) -> Result<(), CliError> {
    reserve_file(byte_path, bytes)?;
    if let Err(error) = reserve_inode_capacity(inode_path, inodes) {
        let cleanup = release_capacity_scope(byte_path, inode_path);
        return Err(combine_errors(
            "reserve rollback inode capacity",
            &error,
            cleanup.err(),
        ));
    }
    Ok(())
}

fn require_atomic_state_store(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    let state_parent = plan
        .state_path
        .parent()
        .ok_or_else(|| io_error("systemd state path has no parent"))?;
    let state_metadata = directory_metadata(state_parent, "systemd state parent")?;
    let store_metadata = directory_metadata(&plan.store_path, "systemd transaction store")?;
    if state_metadata.dev() == store_metadata.dev() {
        Ok(())
    } else {
        Err(io_error(format!(
            "systemd state and transaction store must share a filesystem for atomic rollback: {} and {}",
            state_parent.display(),
            plan.store_path.display()
        )))
    }
}

fn directory_metadata(path: &Path, label: &str) -> Result<Metadata, CliError> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| io_error(format!("inspect {label} {}: {error}", path.display())))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        Err(io_error(format!(
            "{label} is not a regular directory: {}",
            path.display()
        )))
    } else {
        Ok(metadata)
    }
}
