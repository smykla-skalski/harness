use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use fs_err as fs;

use crate::errors::CliError;
use crate::workspace::utc_now;

use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::binary::inspect_binary;
use super::database::{checkpoint_database, database_path, verify_snapshot_database};
use super::files::{
    copy_file_atomic, io_error, regular_file_metadata, remove_tree_if_exists, sha256_file,
    snapshot_optional_file, sync_directory, write_json_atomic,
};
use super::generation_restore::restore_and_restart;
use super::integrity::{generation_digests, verify_generation_integrity};
use super::model::{
    BINARY_FILE, ENVIRONMENT_FILE, FileMetadata, GenerationManifest, MANIFEST_FILE,
    MANIFEST_VERSION, PREVIOUS_OLD_DIRECTORY, RemoteSystemdArtifact, RemoteSystemdHealthReport,
    RemoteSystemdOperationPlan, STATE_DIRECTORY, UNIT_FILE,
};
use super::ownership::ClaimedLifecycle;
use super::state::{snapshot_state_tree, validate_state_tree};
use super::systemd::{
    observe_systemd, release_inhibitor, start_and_verify, stop_and_inhibit, systemctl_checked,
    upgrade_unit_to_notify,
};
use super::unit_contract::validate_inhibited_managed_unit_contract;

pub(super) fn recover_pending_generation<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    reconcile_rotation_state(plan)?;
    let pending = plan.pending_path();
    if !pending.exists() {
        return Ok(());
    }
    let manifest_path = pending.join(MANIFEST_FILE);
    if !manifest_path.exists() {
        remove_tree_if_exists(&pending)?;
        let observation = observe_systemd(plan, run_systemctl)?;
        if observation.active_state != "active" || observation.main_pid == 0 {
            let current = inspect_binary(&plan.binary_path, &plan.binary_path)?;
            restart_existing_service(plan, &current.sha256, run_systemctl, verify_health)?;
        }
        release_inhibitor(plan, run_systemctl)?;
        return Ok(());
    }
    let manifest = load_manifest(&pending)?;
    manifest.validate_for(plan)?;
    restore_and_restart(
        plan,
        &pending,
        &manifest,
        lifecycle,
        run_systemctl,
        verify_health,
    )?;
    let recovered = plan
        .store_path
        .join(format!("recovered-{}", manifest.transaction_id));
    remove_tree_if_exists(&recovered)?;
    fs::rename(&pending, &recovered).map_err(|error| {
        io_error(format!(
            "retain recovered systemd generation {}: {error}",
            recovered.display()
        ))
    })?;
    sync_directory(&plan.store_path)?;
    release_inhibitor(plan, run_systemctl)
}

pub(super) fn reconcile_rotation_state(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    let previous = plan.previous_path();
    let old = plan.store_path.join(PREVIOUS_OLD_DIRECTORY);
    match fs::symlink_metadata(&old) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(io_error(format!(
                "interrupted generation is not a regular directory: {}",
                old.display()
            )));
        }
        Ok(_) => {}
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(io_error(format!(
                "inspect interrupted generation {}: {error}",
                old.display()
            )));
        }
    }
    if previous.exists() {
        remove_tree_if_exists(&old)?;
    } else {
        fs::rename(&old, &previous).map_err(|error| {
            io_error(format!(
                "restore interrupted previous generation {}: {error}",
                previous.display()
            ))
        })?;
    }
    sync_directory(&plan.store_path)
}

pub(super) fn snapshot_generation(
    plan: &RemoteSystemdOperationPlan,
    destination: &Path,
    transaction_id: &str,
    artifact: &RemoteSystemdArtifact,
) -> Result<GenerationManifest, CliError> {
    let binary_metadata = FileMetadata::read(&plan.binary_path)?;
    copy_file_atomic(
        &plan.binary_path,
        &destination.join(BINARY_FILE),
        binary_metadata,
    )?;
    verify_generation_binary(
        &destination.join(BINARY_FILE),
        &artifact.sha256,
        "copied rollback generation binary",
    )?;
    let unit_metadata = snapshot_optional_file(&plan.unit_path, &destination.join(UNIT_FILE))?;
    let environment_metadata =
        snapshot_optional_file(&plan.environment_path, &destination.join(ENVIRONMENT_FILE))?;
    validate_state_tree(&plan.state_path)?;
    let (database_present, database_schema) =
        checkpoint_database(&database_path(&plan.state_path))?;
    let state_present = snapshot_state_tree(&plan.state_path, &destination.join(STATE_DIRECTORY))?;
    verify_snapshot_database(
        &destination.join(STATE_DIRECTORY),
        database_present,
        database_schema,
    )?;
    let digests = generation_digests(
        destination,
        unit_metadata.is_some(),
        environment_metadata.is_some(),
        state_present,
    )?;
    let manifest = GenerationManifest {
        manifest_version: MANIFEST_VERSION,
        transaction_id: transaction_id.to_string(),
        unit: plan.unit.clone(),
        created_at: utc_now(),
        binary_path: plan.binary_path.clone(),
        unit_path: plan.unit_path.clone(),
        environment_path: plan.environment_path.clone(),
        state_path: plan.state_path.clone(),
        binary_version: artifact.version.clone(),
        binary_sha256: artifact.sha256.clone(),
        unit_sha256: digests.unit,
        environment_sha256: digests.environment,
        state_sha256: digests.state,
        binary_metadata,
        unit_metadata,
        environment_metadata,
        state_present,
        database_present,
        database_schema,
    };
    write_json_atomic(&destination.join(MANIFEST_FILE), &manifest)?;
    sync_directory(destination)?;
    Ok(manifest)
}

pub(super) fn activate_candidate<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    staged_candidate: &Path,
    candidate_sha256: &str,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdHealthReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    lifecycle.recheck(run_systemctl)?;
    let installed_metadata = FileMetadata::read(&plan.binary_path)?;
    copy_file_atomic(staged_candidate, &plan.binary_path, installed_metadata)?;
    let installed_sha = super::files::sha256_file(&plan.binary_path)?;
    if installed_sha != candidate_sha256 {
        return Err(io_error(format!(
            "installed candidate digest mismatch: expected {candidate_sha256}, found {installed_sha}"
        )));
    }
    upgrade_unit_to_notify(&plan.unit_path)?;
    systemctl_checked(run_systemctl, &["daemon-reload".to_string()])?;
    validate_inhibited_managed_unit_contract(plan, run_systemctl)?;
    start_and_verify(plan, candidate_sha256, run_systemctl, verify_health)
}

pub(super) fn preflight_generation(
    plan: &RemoteSystemdOperationPlan,
    generation_path: &Path,
    manifest: &GenerationManifest,
) -> Result<(), CliError> {
    manifest.validate_for(plan)?;
    verify_generation_binary(
        &generation_path.join(BINARY_FILE),
        &manifest.binary_sha256,
        "rollback generation binary",
    )?;
    verify_snapshot_database(
        &generation_path.join(STATE_DIRECTORY),
        manifest.database_present,
        manifest.database_schema,
    )?;
    verify_generation_integrity(generation_path, manifest)
}

fn verify_generation_binary(
    path: &Path,
    expected_sha256: &str,
    label: &str,
) -> Result<(), CliError> {
    let observed = sha256_file(path)?;
    if observed == expected_sha256 {
        Ok(())
    } else {
        Err(io_error(format!(
            "{label} digest mismatch for {}: expected {expected_sha256}, found {observed}",
            path.display()
        )))
    }
}

pub(super) fn restart_existing_service<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    expected_sha256: &str,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdHealthReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    stop_and_inhibit(plan, run_systemctl)?;
    start_and_verify(plan, expected_sha256, run_systemctl, verify_health)
}

pub(super) fn load_manifest(generation_path: &Path) -> Result<GenerationManifest, CliError> {
    let path = generation_path.join(MANIFEST_FILE);
    regular_file_metadata(&path)?;
    let bytes = fs::read(&path).map_err(|error| {
        io_error(format!(
            "read rollback manifest {}: {error}",
            path.display()
        ))
    })?;
    serde_json::from_slice(&bytes).map_err(|error| {
        io_error(format!(
            "decode rollback manifest {}: {error}",
            path.display()
        ))
    })
}

pub(super) fn transaction_generation_path(
    plan: &RemoteSystemdOperationPlan,
    transaction_id: &str,
) -> Result<PathBuf, CliError> {
    for path in [plan.pending_path(), plan.previous_path()] {
        if !path.join(MANIFEST_FILE).exists() {
            continue;
        }
        let manifest = load_manifest(&path)?;
        if manifest.transaction_id == transaction_id {
            return Ok(path);
        }
    }
    Err(io_error(format!(
        "cannot locate rollback generation for transaction {transaction_id}"
    )))
}

pub(super) fn promote_pending_generation(
    plan: &RemoteSystemdOperationPlan,
) -> Result<PathBuf, CliError> {
    let pending = plan.pending_path();
    let previous = plan.previous_path();
    let old = plan.store_path.join(PREVIOUS_OLD_DIRECTORY);
    remove_tree_if_exists(&old)?;
    if previous.exists() {
        fs::rename(&previous, &old).map_err(|error| {
            io_error(format!(
                "rotate previous generation {}: {error}",
                previous.display()
            ))
        })?;
    }
    if let Err(error) = fs::rename(&pending, &previous) {
        if old.exists() {
            let _ = fs::rename(&old, &previous);
        }
        return Err(io_error(format!(
            "commit systemd generation {}: {error}",
            previous.display()
        )));
    }
    sync_directory(&plan.store_path)?;
    remove_tree_if_exists(&old)?;
    sync_directory(&plan.store_path)?;
    Ok(previous)
}

pub(super) fn swap_previous_with_pending(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    let previous = plan.previous_path();
    let pending = plan.pending_path();
    let old = plan.store_path.join(PREVIOUS_OLD_DIRECTORY);
    remove_tree_if_exists(&old)?;
    fs::rename(&previous, &old).map_err(|error| {
        io_error(format!(
            "consume rollback generation {}: {error}",
            previous.display()
        ))
    })?;
    if let Err(error) = fs::rename(&pending, &previous) {
        let _ = fs::rename(&old, &previous);
        return Err(io_error(format!(
            "retain displaced generation {}: {error}",
            previous.display()
        )));
    }
    sync_directory(&plan.store_path)?;
    remove_tree_if_exists(&old)?;
    sync_directory(&plan.store_path)
}

#[cfg(test)]
pub(crate) fn reconcile_rotation_state_for_tests(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    reconcile_rotation_state(plan)
}

#[cfg(test)]
pub(crate) fn snapshot_generation_for_tests(
    plan: &RemoteSystemdOperationPlan,
    destination: &Path,
    artifact: &RemoteSystemdArtifact,
) -> Result<(), CliError> {
    snapshot_generation(plan, destination, "test-transaction", artifact).map(|_| ())
}

pub(super) fn retain_failed_generation(
    plan: &RemoteSystemdOperationPlan,
    transaction_id: &str,
) -> Result<PathBuf, CliError> {
    let pending = plan.pending_path();
    let failed = plan.store_path.join(format!("failed-{transaction_id}"));
    remove_tree_if_exists(&failed)?;
    fs::rename(&pending, &failed).map_err(|error| {
        io_error(format!(
            "retain failed generation {}: {error}",
            failed.display()
        ))
    })?;
    sync_directory(&plan.store_path)?;
    Ok(failed)
}

pub(super) fn retain_recovered_generation(
    plan: &RemoteSystemdOperationPlan,
    transaction_id: &str,
) -> Result<PathBuf, CliError> {
    let pending = plan.pending_path();
    let recovered = plan.store_path.join(format!("recovered-{transaction_id}"));
    remove_tree_if_exists(&recovered)?;
    fs::rename(&pending, &recovered).map_err(|error| {
        io_error(format!(
            "retain recovered systemd generation {}: {error}",
            recovered.display()
        ))
    })?;
    sync_directory(&plan.store_path)?;
    Ok(recovered)
}
