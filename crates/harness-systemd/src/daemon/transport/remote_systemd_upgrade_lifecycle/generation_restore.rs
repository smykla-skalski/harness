use std::path::{Path, PathBuf};

use crate::errors::CliError;

use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::capacity::{
    ensure_restore_capacity, reconcile_restore_debris, release_binary_restore_capacity,
    release_restore_capacity, release_state_restore_capacity, required_restore_capacity,
};
use super::database::verify_restored_database;
use super::files::{copy_file_atomic, restore_optional_file};
use super::generation::preflight_generation;
use super::integrity::{
    installed_binary_matches, installed_environment_matches, installed_state_matches,
    installed_unit_matches, verify_installed_generation,
};
use super::model::{
    BINARY_FILE, ENVIRONMENT_FILE, GenerationManifest, RemoteSystemdHealthReport,
    RemoteSystemdOperationPlan, STATE_DIRECTORY, UNIT_FILE,
};
use super::ownership::ClaimedLifecycle;
use super::state::{restore_state_tree, restore_state_tree_retaining_current};
use super::systemd::{start_and_verify, stop_for_restore, systemctl_checked};
use super::unit_contract::validate_inhibited_managed_unit_contract;

pub(super) fn restore_and_restart<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    generation_path: &Path,
    manifest: &GenerationManifest,
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
    restore_generation(plan, generation_path, manifest, lifecycle, run_systemctl)?;
    start_and_verify(plan, &manifest.binary_sha256, run_systemctl, verify_health)
}

pub(super) fn restore_generation<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    generation_path: &Path,
    manifest: &GenerationManifest,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    restore_generation_internal(
        plan,
        generation_path,
        manifest,
        None,
        lifecycle,
        run_systemctl,
    )
}

pub(super) fn restore_generation_retaining_current<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    generation_path: &Path,
    manifest: &GenerationManifest,
    retention_path: &Path,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    restore_generation_internal(
        plan,
        generation_path,
        manifest,
        Some(retention_path),
        lifecycle,
        run_systemctl,
    )
}

fn restore_generation_internal<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    generation_path: &Path,
    manifest: &GenerationManifest,
    retention_path: Option<&Path>,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    preflight_generation(plan, generation_path, manifest)?;
    stop_for_restore(plan, run_systemctl)?;
    reconcile_restore_debris(plan)?;
    let delta = RestoreDelta::inspect(plan, manifest);
    ensure_delta_capacity(plan, generation_path, manifest, delta)?;
    if delta.files_needed() {
        release_binary_restore_capacity(plan)?;
    }
    if delta.binary.is_needed() {
        lifecycle.recheck(run_systemctl)?;
    }
    restore_changed_files(plan, generation_path, manifest, delta)?;
    if delta.state.is_needed() {
        release_state_restore_capacity(plan)?;
        restore_generation_state(plan, generation_path, manifest, retention_path)?;
    }
    release_restore_capacity(plan)?;
    verify_restored_database(
        &plan.state_path,
        manifest.database_present,
        manifest.database_schema,
    )?;
    verify_installed_generation(plan, manifest)?;
    systemctl_checked(run_systemctl, &["daemon-reload".to_string()])?;
    validate_inhibited_managed_unit_contract(plan, run_systemctl)
}

#[derive(Clone, Copy)]
struct RestoreDelta {
    binary: RestoreRequirement,
    unit: RestoreRequirement,
    environment: RestoreRequirement,
    state: RestoreRequirement,
}

#[derive(Clone, Copy)]
enum RestoreRequirement {
    Current,
    Needed,
}

impl RestoreRequirement {
    const fn inspect(matches: bool) -> Self {
        if !matches {
            return Self::Needed;
        }
        Self::Current
    }

    const fn is_needed(self) -> bool {
        matches!(self, Self::Needed)
    }
}

impl RestoreDelta {
    fn inspect(plan: &RemoteSystemdOperationPlan, manifest: &GenerationManifest) -> Self {
        Self {
            binary: RestoreRequirement::inspect(installed_binary_matches(plan, manifest)),
            unit: RestoreRequirement::inspect(installed_unit_matches(plan, manifest)),
            environment: RestoreRequirement::inspect(installed_environment_matches(plan, manifest)),
            state: RestoreRequirement::inspect(installed_state_matches(plan, manifest)),
        }
    }

    const fn files_needed(self) -> bool {
        self.binary.is_needed() || self.unit.is_needed() || self.environment.is_needed()
    }
}

fn ensure_delta_capacity(
    plan: &RemoteSystemdOperationPlan,
    generation_path: &Path,
    manifest: &GenerationManifest,
    delta: RestoreDelta,
) -> Result<(), CliError> {
    let state_source = generation_path.join(STATE_DIRECTORY);
    let file_sources = changed_file_sources(generation_path, manifest, delta);
    let file_source_refs = file_sources
        .iter()
        .map(PathBuf::as_path)
        .collect::<Vec<_>>();
    let capacity = required_restore_capacity(plan, &[&state_source], &file_source_refs)?;
    ensure_restore_capacity(
        plan,
        capacity,
        delta.state.is_needed(),
        !file_sources.is_empty(),
    )
}

fn changed_file_sources(
    generation_path: &Path,
    manifest: &GenerationManifest,
    delta: RestoreDelta,
) -> Vec<PathBuf> {
    let mut sources = Vec::new();
    if delta.binary.is_needed() {
        sources.push(generation_path.join(BINARY_FILE));
    }
    if delta.unit.is_needed() && manifest.unit_metadata.is_some() {
        sources.push(generation_path.join(UNIT_FILE));
    }
    if delta.environment.is_needed() && manifest.environment_metadata.is_some() {
        sources.push(generation_path.join(ENVIRONMENT_FILE));
    }
    sources
}

fn restore_changed_files(
    plan: &RemoteSystemdOperationPlan,
    generation_path: &Path,
    manifest: &GenerationManifest,
    delta: RestoreDelta,
) -> Result<(), CliError> {
    if delta.binary.is_needed() {
        copy_file_atomic(
            &generation_path.join(BINARY_FILE),
            &plan.binary_path,
            manifest.binary_metadata,
        )?;
    }
    if delta.unit.is_needed() {
        restore_optional_file(
            &generation_path.join(UNIT_FILE),
            &plan.unit_path,
            manifest.unit_metadata,
        )?;
    }
    if delta.environment.is_needed() {
        restore_optional_file(
            &generation_path.join(ENVIRONMENT_FILE),
            &plan.environment_path,
            manifest.environment_metadata,
        )?;
    }
    Ok(())
}

fn restore_generation_state(
    plan: &RemoteSystemdOperationPlan,
    generation_path: &Path,
    manifest: &GenerationManifest,
    retention_path: Option<&Path>,
) -> Result<(), CliError> {
    let state_source = generation_path.join(STATE_DIRECTORY);
    if let Some(retention_path) = retention_path {
        restore_state_tree_retaining_current(
            &state_source,
            &plan.state_path,
            manifest.state_present,
            retention_path,
        )
    } else {
        restore_state_tree(&state_source, &plan.state_path, manifest.state_present)
    }
}
