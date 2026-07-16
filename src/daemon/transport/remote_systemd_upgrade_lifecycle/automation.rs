#[cfg(all(target_os = "linux", not(test)))]
use nix::unistd::syncfs;
#[cfg(all(target_os = "linux", not(test)))]
use std::fs::File;
use std::path::Path;

use crate::errors::CliError;

use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::capacity::release_restore_capacity;
use super::files::{
    combine_errors, combine_results, copy_recovery_controller_atomic, io_error,
    remove_file_if_exists, sync_directory,
};
use super::model::{
    DatabaseSeal, FileMetadata, RECOVERY_ARM_VERSION, RecoveryArm, RecoveryOperation,
    RecoveryPhase, RemoteSystemdOperationPlan,
};
use super::systemd::{release_inhibitor, stop_and_inhibit};
use super::unit_contract::validate_managed_unit_contract;

#[path = "automation/recovery_arm.rs"]
mod recovery_arm;
#[path = "automation/recovery_units.rs"]
mod recovery_units;

use recovery_arm::write_recovery_arm;
pub(super) use recovery_units::{remove_recovery_unit_files_at, validate_recovery_unit_files_at};
use recovery_units::{
    remove_recovery_unit_files_if_managed, validate_recovery_timer_active,
    validate_recovery_unit_files, validate_recovery_unit_sources, write_recovery_units,
};

pub(super) fn load_recovery_arm(store_path: &Path) -> Result<Option<RecoveryArm>, CliError> {
    recovery_arm::load_recovery_arm(store_path)
}

pub(super) fn arm_recovery_automation<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    controller_source: &Path,
    transaction_id: &str,
    operation: RecoveryOperation,
    before_sha256: &str,
    target_sha256: &str,
    run_systemctl: &RunSystemctl,
) -> Result<RecoveryArm, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let original_enabled = original_daemon_enablement(plan, run_systemctl)?;
    let arm = RecoveryArm {
        arm_version: RECOVERY_ARM_VERSION,
        transaction_id: transaction_id.to_string(),
        operation,
        phase: RecoveryPhase::Armed,
        unit: plan.unit.clone(),
        binary_path: plan.binary_path.clone(),
        unit_path: plan.unit_path.clone(),
        environment_path: plan.environment_path.clone(),
        state_path: plan.state_path.clone(),
        store_path: plan.store_path.clone(),
        readiness_timeout_seconds: plan.readiness_timeout.as_secs(),
        stabilization_window_seconds: plan.stabilization_window.as_secs(),
        original_enabled,
        before_sha256: before_sha256.to_string(),
        target_sha256: target_sha256.to_string(),
        target_database_seal: None,
    };
    validate_recovery_unit_files(plan)?;
    let material = copy_recovery_controller_atomic(
        controller_source,
        &plan.recovery_controller_path(),
        FileMetadata::private_executable(),
    )
    .and_then(|()| write_recovery_units(plan));
    if let Err(error) = material {
        return Err(clean_pre_disable_failure(plan, &error, run_systemctl));
    }
    let reload = systemctl_checked(run_systemctl, &["daemon-reload".to_string()])
        .and_then(|()| validate_managed_unit_contract(plan, run_systemctl));
    if let Err(error) = reload {
        return Err(clean_pre_disable_failure(plan, &error, run_systemctl));
    }
    if let Err(error) = enable_recovery_timer(plan, run_systemctl) {
        return Err(clean_pre_disable_failure(plan, &error, run_systemctl));
    }
    if let Err(error) = write_recovery_arm(plan, &arm) {
        return Err(clean_pre_disable_failure(plan, &error, run_systemctl));
    }
    ensure_daemon_disabled(plan, run_systemctl)?;
    Ok(arm)
}

fn clean_pre_disable_failure<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    primary: &CliError,
    run_systemctl: &RunSystemctl,
) -> CliError
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let arm_cleanup = remove_file_if_exists(&plan.recovery_arm_path())
        .and_then(|()| sync_directory(&plan.store_path));
    if let Err(error) = arm_cleanup {
        return combine_errors("clean failed systemd recovery arm", primary, Some(error));
    }
    let timer_cleanup = systemctl_checked(
        run_systemctl,
        &[
            "disable".to_string(),
            "--now".to_string(),
            plan.recovery_timer_name(),
        ],
    )
    .and_then(|()| sync_systemd_unit_filesystem(plan));
    let file_cleanup = remove_recovery_unit_files_if_managed(plan)
        .and_then(|()| remove_file_if_exists(&plan.recovery_controller_path()));
    let reload = systemctl_checked(run_systemctl, &["daemon-reload".to_string()])
        .and_then(|()| validate_managed_unit_contract(plan, run_systemctl));
    let cleanup = release_restore_capacity(plan)
        .and(timer_cleanup)
        .and(file_cleanup)
        .and(reload);
    combine_errors("arm systemd recovery automation", primary, cleanup.err())
}

pub(super) fn update_recovery_phase(
    plan: &RemoteSystemdOperationPlan,
    arm: &mut RecoveryArm,
    phase: RecoveryPhase,
) -> Result<(), CliError> {
    let previous = arm.phase;
    arm.phase = phase;
    if let Err(error) = write_recovery_arm(plan, arm) {
        arm.phase = previous;
        return Err(error);
    }
    Ok(())
}

pub(super) fn record_target_database_seal(
    plan: &RemoteSystemdOperationPlan,
    arm: &mut RecoveryArm,
    seal: DatabaseSeal,
) -> Result<(), CliError> {
    if arm.phase != RecoveryPhase::RollbackReady {
        return Err(io_error(format!(
            "cannot seal target database while systemd transaction {} is in phase {:?}",
            arm.transaction_id, arm.phase
        )));
    }
    seal.validate()?;
    match arm.target_database_seal {
        Some(recorded) if recorded == seal => return Ok(()),
        Some(recorded) => {
            return Err(io_error(format!(
                "target database seal changed for systemd transaction {}: recorded {recorded:?}, found {seal:?}",
                arm.transaction_id
            )));
        }
        None => {}
    }
    arm.target_database_seal = Some(seal);
    if let Err(error) = write_recovery_arm(plan, arm) {
        arm.target_database_seal = None;
        return Err(error);
    }
    Ok(())
}

pub(super) fn finish_recovery_automation<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    arm: &RecoveryArm,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    if let Err(error) = restore_daemon_enablement(plan, arm.original_enabled, run_systemctl) {
        return Err(finish_failure(plan, arm, &error, run_systemctl));
    }
    if let Err(error) = release_inhibitor(plan, run_systemctl) {
        return Err(finish_failure(plan, arm, &error, run_systemctl));
    }
    let remove_result = remove_file_if_exists(&plan.recovery_arm_path())
        .and_then(|()| sync_directory(&plan.store_path));
    if let Err(error) = remove_result {
        return Err(finish_failure(plan, arm, &error, run_systemctl));
    }
    release_restore_capacity(plan)
}

fn finish_failure<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    arm: &RecoveryArm,
    error: &CliError,
    run_systemctl: &RunSystemctl,
) -> CliError
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let rewrite_arm = write_recovery_arm(plan, arm);
    let inhibit_daemon = stop_and_inhibit(plan, run_systemctl);
    let disable_daemon = ensure_daemon_disabled(plan, run_systemctl);
    let enable_timer = enable_recovery_timer(plan, run_systemctl);
    let recovery = combine_results(
        "rewrite recovery arm and inhibit systemd service",
        rewrite_arm,
        inhibit_daemon,
    );
    let recovery = combine_results(
        "secure failed systemd transaction",
        recovery,
        disable_daemon,
    );
    let recovery = combine_results(
        "enable timer for failed systemd transaction",
        recovery,
        enable_timer,
    );
    super::files::combine_errors("finish systemd transaction", error, recovery.err())
}

pub(super) fn ensure_daemon_disabled<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    systemctl_checked(run_systemctl, &["disable".to_string(), plan.service()])?;
    sync_systemd_unit_filesystem(plan)?;
    if daemon_is_enabled(plan, run_systemctl)? {
        Err(io_error(format!(
            "{} remained enabled after transaction guard",
            plan.service()
        )))
    } else {
        Ok(())
    }
}

fn restore_daemon_enablement<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    enabled: bool,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let action = if enabled { "enable" } else { "disable" };
    systemctl_checked(run_systemctl, &[action.to_string(), plan.service()])?;
    sync_systemd_unit_filesystem(plan)?;
    let observed = daemon_is_enabled(plan, run_systemctl)?;
    if observed == enabled {
        Ok(())
    } else {
        Err(io_error(format!(
            "{} enablement did not restore to {enabled}",
            plan.service()
        )))
    }
}

pub(super) fn daemon_is_enabled<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<bool, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let state = daemon_enablement_state(plan, run_systemctl)?;
    match state.as_str() {
        "enabled" => Ok(true),
        "disabled" | "masked" | "masked-runtime" => Ok(false),
        _ => Err(io_error(format!(
            "unsupported systemd enablement state for {}: {state}",
            plan.service()
        ))),
    }
}

fn original_daemon_enablement<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<bool, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let state = daemon_enablement_state(plan, run_systemctl)?;
    match state.as_str() {
        "enabled" => Ok(true),
        "disabled" => Ok(false),
        _ => Err(io_error(format!(
            "{} must not be masked before a transactional operation (state={state})",
            plan.service()
        ))),
    }
}

fn daemon_enablement_state<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<String, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let args = ["is-enabled".to_string(), plan.service()];
    let output = run_systemctl(&args)?;
    let state = output.stdout.trim();
    if matches!(state, "enabled" | "disabled" | "masked" | "masked-runtime") {
        Ok(state.to_string())
    } else {
        Err(io_error(format!(
            "systemctl is-enabled {} returned {}: {} {}",
            plan.service(),
            output.exit_code,
            state,
            output.stderr.trim()
        )))
    }
}

fn enable_recovery_timer<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    validate_recovery_unit_sources(plan, run_systemctl)?;
    systemctl_checked(
        run_systemctl,
        &[
            "enable".to_string(),
            "--now".to_string(),
            plan.recovery_timer_name(),
        ],
    )?;
    sync_systemd_unit_filesystem(plan)?;
    validate_recovery_timer_active(plan, run_systemctl)
}

pub(super) fn sync_systemd_unit_filesystem(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    let parent = plan
        .unit_path
        .parent()
        .ok_or_else(|| io_error("systemd unit path has no parent"))?;
    #[cfg(all(target_os = "linux", not(test)))]
    {
        let directory = File::open(parent).map_err(|error| {
            io_error(format!(
                "open systemd unit filesystem {}: {error}",
                parent.display()
            ))
        })?;
        syncfs(&directory).map_err(|error| {
            io_error(format!(
                "sync systemd unit filesystem {}: {error}",
                parent.display()
            ))
        })
    }
    #[cfg(any(not(target_os = "linux"), test))]
    {
        sync_directory(parent)
    }
}

pub(super) fn systemctl_checked<RunSystemctl>(
    run_systemctl: &RunSystemctl,
    args: &[String],
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let output = run_systemctl(args)?;
    if output.exit_code == 0 {
        Ok(())
    } else {
        Err(io_error(format!(
            "systemctl {} failed with exit code {}: {}",
            shell_words::join(args.iter().map(String::as_str)),
            output.exit_code,
            output.stderr.trim()
        )))
    }
}

#[cfg(test)]
pub(crate) fn render_recovery_units_for_tests(
    plan: &RemoteSystemdOperationPlan,
) -> (String, String) {
    recovery_units::render_recovery_units(plan)
}
