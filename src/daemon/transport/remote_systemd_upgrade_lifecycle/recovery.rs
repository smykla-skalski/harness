use std::io::ErrorKind;
use std::path::Path;

use fs_err as fs;

use crate::errors::CliError;

use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::automation::{
    ensure_daemon_disabled, finish_recovery_automation, load_recovery_arm, update_recovery_phase,
};
use super::capacity::release_restore_capacity;
use super::files::{combine_results, io_error, remove_tree_if_exists, sha256_file, sync_directory};
use super::generation::{
    load_manifest, reconcile_rotation_state, recover_pending_generation, restart_existing_service,
    retain_recovered_generation,
};
use super::generation_restore::{restore_generation, restore_generation_retaining_current};
use super::model::{
    MANIFEST_FILE, MANIFEST_VERSION, PENDING_DIRECTORY, PREVIOUS_OLD_DIRECTORY, RecoveryArm,
    RecoveryOperation, RecoveryPhase, RemoteSystemdHealthReport, RemoteSystemdOperationPlan,
    RemoteSystemdRecoveryOutcome, RemoteSystemdRecoveryReport,
};
use super::ownership::{BindMode, ClaimedLifecycle, LockedLifecycle};
use super::systemd::stop_and_inhibit;

#[path = "recovery/committed.rs"]
mod committed;

pub(crate) fn recover_remote_systemd_with<RunSystemctl, VerifyHealth>(
    store_path: &Path,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdRecoveryReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let store = RecoveryStore::inspect(store_path)?;
    let Some(locked) =
        LockedLifecycle::try_acquire(store.transaction_root, store.unit, store.path)?
    else {
        return Ok(deferred_report());
    };
    let Some(arm) = load_recovery_arm(store.path)? else {
        return Ok(noop_report());
    };
    recover_loaded_transaction(&store, locked, arm, run_systemctl, verify_health)
}

struct RecoveryStore<'a> {
    path: &'a Path,
    transaction_root: &'a Path,
    unit: &'a str,
}

impl<'a> RecoveryStore<'a> {
    fn inspect(path: &'a Path) -> Result<Self, CliError> {
        let transaction_root = path
            .parent()
            .ok_or_else(|| io_error("systemd recovery store has no transaction root"))?;
        let unit = path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| io_error("systemd recovery store has no UTF-8 unit name"))?;
        Ok(Self {
            path,
            transaction_root,
            unit,
        })
    }

    fn validate_plan(&self, plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
        if plan.unit == self.unit && plan.store_path == self.path {
            Ok(())
        } else {
            Err(io_error(format!(
                "systemd recovery store mismatch: expected {}, found {}",
                self.path.display(),
                plan.store_path.display()
            )))
        }
    }
}

fn recover_loaded_transaction<RunSystemctl, VerifyHealth>(
    store: &RecoveryStore<'_>,
    locked: LockedLifecycle,
    arm: RecoveryArm,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdRecoveryReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let plan = arm.plan()?;
    store.validate_plan(&plan)?;
    let lifecycle = locked.bind(&plan.binary_path, BindMode::ExistingOnly, run_systemctl)?;
    recover_armed_transaction(&plan, arm, &lifecycle, run_systemctl, verify_health)
}

pub(super) fn recover_before_operation<RunSystemctl, VerifyHealth>(
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
    if let Some(arm) = load_recovery_arm(&plan.store_path)? {
        validate_arm_plan(plan, &arm)?;
        recover_armed_transaction(plan, arm, lifecycle, run_systemctl, verify_health)?;
    } else {
        recover_pending_generation(plan, lifecycle, run_systemctl, verify_health)?;
        release_restore_capacity(plan)?;
    }
    Ok(())
}

pub(in crate::daemon::transport) fn ensure_systemd_lifecycle_unarmed(
    store_path: &Path,
) -> Result<(), CliError> {
    if load_recovery_arm(store_path)?.is_some() {
        return Err(io_error(format!(
            "refusing systemd install or uninstall while a transaction is armed in {}",
            store_path.display()
        )));
    }
    for (label, path) in [
        ("pending generation", store_path.join(PENDING_DIRECTORY)),
        (
            "interrupted generation rotation",
            store_path.join(PREVIOUS_OLD_DIRECTORY),
        ),
    ] {
        if path_entry_exists(&path)? {
            return Err(io_error(format!(
                "refusing systemd install or uninstall while {label} requires lifecycle recovery in {}",
                path.display()
            )));
        }
    }
    Ok(())
}

fn path_entry_exists(path: &Path) -> Result<bool, CliError> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(io_error(format!(
            "inspect systemd lifecycle entry {}: {error}",
            path.display()
        ))),
    }
}

fn recover_armed_transaction<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    arm: RecoveryArm,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdRecoveryReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let inhibited = stop_and_inhibit(plan, run_systemctl);
    let disabled = ensure_daemon_disabled(plan, run_systemctl);
    combine_results(
        "quiesce and disable systemd service for recovery",
        inhibited,
        disabled,
    )?;
    reconcile_rotation_state(plan)?;
    if plan.pending_path().exists() {
        recover_uncommitted(plan, arm, lifecycle, run_systemctl, verify_health)
    } else {
        finish_terminal_state(plan, &arm, lifecycle, run_systemctl, verify_health)
    }
}

fn recover_uncommitted<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    arm: RecoveryArm,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdRecoveryReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    if plan.pending_path().join(MANIFEST_FILE).exists() {
        if arm.phase == RecoveryPhase::Armed {
            finish_complete_pre_activation(plan, arm, run_systemctl, verify_health)
        } else {
            recover_complete_pending(plan, arm, lifecycle, run_systemctl, verify_health)
        }
    } else {
        recover_incomplete_pending(plan, arm, run_systemctl, verify_health)
    }
}

fn finish_complete_pre_activation<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    mut arm: RecoveryArm,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdRecoveryReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let manifest = load_manifest(&plan.pending_path())?;
    manifest.validate_for(plan)?;
    validate_manifest_transaction(&arm, &manifest.transaction_id, &manifest.binary_sha256)?;
    verify_installed_sha(plan, &arm.before_sha256)?;
    update_recovery_phase(plan, &mut arm, RecoveryPhase::RollbackFinalizing)?;
    retain_recovered_generation(plan, &arm.transaction_id)?;
    restart_existing_service(plan, &arm.before_sha256, run_systemctl, verify_health)?;
    finish_recovery_automation(plan, &arm, run_systemctl)?;
    Ok(recovery_report(
        &arm,
        RemoteSystemdRecoveryOutcome::RolledBack,
        "discarded a complete pre-activation snapshot without restoring live state",
    ))
}

fn recover_complete_pending<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    mut arm: RecoveryArm,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdRecoveryReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let manifest = load_manifest(&plan.pending_path())?;
    manifest.validate_for(plan)?;
    validate_manifest_transaction(&arm, &manifest.transaction_id, &manifest.binary_sha256)?;
    if arm.operation == RecoveryOperation::Upgrade {
        let failed_state_path = plan.failed_current_state_path(&arm.transaction_id);
        restore_generation_retaining_current(
            plan,
            &plan.pending_path(),
            &manifest,
            &failed_state_path,
            lifecycle,
            run_systemctl,
        )?;
    } else {
        restore_generation(
            plan,
            &plan.pending_path(),
            &manifest,
            lifecycle,
            run_systemctl,
        )?;
    }
    update_recovery_phase(plan, &mut arm, RecoveryPhase::RollbackFinalizing)?;
    retain_recovered_generation(plan, &arm.transaction_id)?;
    restart_existing_service(plan, &arm.before_sha256, run_systemctl, verify_health)?;
    finish_recovery_automation(plan, &arm, run_systemctl)?;
    Ok(recovery_report(
        &arm,
        RemoteSystemdRecoveryOutcome::RolledBack,
        "restored the complete pre-transaction generation",
    ))
}

fn recover_incomplete_pending<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    mut arm: RecoveryArm,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdRecoveryReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    verify_installed_sha(plan, &arm.before_sha256)?;
    update_recovery_phase(plan, &mut arm, RecoveryPhase::RollbackFinalizing)?;
    remove_tree_if_exists(&plan.pending_path())?;
    sync_directory(&plan.store_path)?;
    restart_existing_service(plan, &arm.before_sha256, run_systemctl, verify_health)?;
    finish_recovery_automation(plan, &arm, run_systemctl)?;
    Ok(recovery_report(
        &arm,
        RemoteSystemdRecoveryOutcome::RolledBack,
        "discarded incomplete staging before candidate installation",
    ))
}

fn finish_terminal_state<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    arm: &RecoveryArm,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdRecoveryReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    match arm.phase {
        RecoveryPhase::Committing => {
            committed::finish_committed(plan, arm, lifecycle, run_systemctl, verify_health)
        }
        RecoveryPhase::Armed => finish_rolled_back(plan, arm, run_systemctl, verify_health),
        RecoveryPhase::RollbackFinalizing => {
            finish_rolled_back(plan, arm, run_systemctl, verify_health)
        }
        RecoveryPhase::RollbackReady => Err(io_error(format!(
            "systemd transaction {} lost its pending generation before a terminal phase",
            arm.transaction_id
        ))),
    }
}

fn finish_rolled_back<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    arm: &RecoveryArm,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdRecoveryReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    verify_installed_sha(plan, &arm.before_sha256)?;
    restart_existing_service(plan, &arm.before_sha256, run_systemctl, verify_health)?;
    finish_recovery_automation(plan, arm, run_systemctl)?;
    Ok(recovery_report(
        arm,
        RemoteSystemdRecoveryOutcome::RolledBack,
        "completed enablement after rollback",
    ))
}

fn validate_manifest_transaction(
    arm: &RecoveryArm,
    transaction_id: &str,
    binary_sha256: &str,
) -> Result<(), CliError> {
    if transaction_id != arm.transaction_id {
        return Err(io_error(format!(
            "pending generation belongs to transaction {transaction_id}, not {}",
            arm.transaction_id
        )));
    }
    if binary_sha256 != arm.before_sha256 {
        return Err(io_error(format!(
            "pending generation binary digest does not match transaction {}",
            arm.transaction_id
        )));
    }
    Ok(())
}

fn validate_arm_plan(
    expected: &RemoteSystemdOperationPlan,
    arm: &RecoveryArm,
) -> Result<(), CliError> {
    let actual = arm.plan()?;
    if actual.unit != expected.unit
        || actual.binary_path != expected.binary_path
        || actual.unit_path != expected.unit_path
        || actual.environment_path != expected.environment_path
        || actual.state_path != expected.state_path
        || actual.store_path != expected.store_path
    {
        return Err(io_error(format!(
            "armed systemd transaction paths do not match unit {}",
            expected.unit
        )));
    }
    Ok(())
}

fn verify_installed_sha(
    plan: &RemoteSystemdOperationPlan,
    expected_sha256: &str,
) -> Result<(), CliError> {
    let observed = sha256_file(&plan.binary_path)?;
    if observed == expected_sha256 {
        Ok(())
    } else {
        Err(io_error(format!(
            "installed binary digest mismatch during recovery: expected {expected_sha256}, found {observed}"
        )))
    }
}

fn noop_report() -> RemoteSystemdRecoveryReport {
    RemoteSystemdRecoveryReport {
        report_version: MANIFEST_VERSION,
        operation: "recover_systemd".to_string(),
        transaction_id: None,
        unit: None,
        outcome: RemoteSystemdRecoveryOutcome::Noop,
        detail: "no armed systemd transaction".to_string(),
    }
}

fn deferred_report() -> RemoteSystemdRecoveryReport {
    RemoteSystemdRecoveryReport {
        report_version: MANIFEST_VERSION,
        operation: "recover_systemd".to_string(),
        transaction_id: None,
        unit: None,
        outcome: RemoteSystemdRecoveryOutcome::Deferred,
        detail: "active lifecycle process owns the transaction lock".to_string(),
    }
}

fn recovery_report(
    arm: &RecoveryArm,
    outcome: RemoteSystemdRecoveryOutcome,
    detail: impl Into<String>,
) -> RemoteSystemdRecoveryReport {
    RemoteSystemdRecoveryReport {
        report_version: MANIFEST_VERSION,
        operation: "recover_systemd".to_string(),
        transaction_id: Some(arm.transaction_id.clone()),
        unit: Some(arm.unit.clone()),
        outcome,
        detail: detail.into(),
    }
}
