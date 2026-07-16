use std::path::{Path, PathBuf};

use uuid::Uuid;

use crate::errors::CliError;

use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::automation::{
    arm_recovery_automation, finish_recovery_automation, load_recovery_arm, update_recovery_phase,
};
use super::binary::{acquire_with_trusted_controller, inspect_binary};
use super::capacity::{
    reserve_bidirectional_restore_capacity, reserve_generation_restore_capacity,
    validate_restore_filesystems,
};
use super::files::{
    combine_errors, create_private_directory, remove_tree_if_exists, sync_directory,
};
use super::generation::{
    load_manifest, preflight_generation, restart_existing_service, snapshot_generation,
    swap_previous_with_pending,
};
use super::generation_restore::restore_generation;
use super::model::{
    GenerationManifest, MANIFEST_VERSION, RecoveryArm, RecoveryOperation, RecoveryPhase,
    RemoteSystemdArtifact, RemoteSystemdHealthReport, RemoteSystemdOperationPlan,
    RemoteSystemdRollbackReport, RemoteSystemdUpgradeOutcome,
};
use super::ownership::{BindMode, ClaimedLifecycle, LockedLifecycle};
use super::recovery::recover_before_operation;
use super::systemd::{start_and_verify, stop_and_inhibit};
use super::target_database::seal_and_reverify_target;
use super::unit_contract::validate_managed_unit_contract;

pub(crate) fn rollback_remote_systemd_with<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdRollbackReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let lifecycle = prepare_rollback_lifecycle(plan, run_systemctl, verify_health)?;
    let previous_path = plan.previous_path();
    let restored_manifest = load_manifest(&previous_path)?;
    preflight_generation(plan, &previous_path, &restored_manifest)?;
    let restored = restored_manifest.artifact();
    let displaced = inspect_binary(&plan.binary_path, &plan.binary_path)?;
    verify_health(plan, &displaced.sha256, run_systemctl)?;
    let transaction_id = Uuid::new_v4().simple().to_string();
    let pending = plan.pending_path();
    create_private_directory(&pending)?;

    let mut arm = arm_recovery_automation(
        plan,
        &plan.controller_path,
        &transaction_id,
        RecoveryOperation::Rollback,
        &displaced.sha256,
        &restored.sha256,
        run_systemctl,
    )?;
    stop_and_inhibit(plan, run_systemctl)?;
    let displaced_manifest = match snapshot_generation(plan, &pending, &transaction_id, &displaced)
    {
        Ok(manifest) => manifest,
        Err(error) => {
            let recovery = update_recovery_phase(plan, &mut arm, RecoveryPhase::RollbackFinalizing)
                .and_then(|()| remove_tree_if_exists(&pending))
                .and_then(|()| sync_directory(&plan.store_path))
                .and_then(|()| {
                    restart_existing_service(plan, &displaced.sha256, run_systemctl, verify_health)
                })
                .and_then(|_| finish_recovery_automation(plan, &arm, run_systemctl));
            return Err(combine_errors(
                "snapshot current systemd generation before rollback",
                &error,
                recovery.err(),
            ));
        }
    };
    if let Err(error) = reserve_bidirectional_restore_capacity(
        plan,
        &previous_path,
        &restored_manifest,
        &pending,
        &displaced_manifest,
    ) {
        let recovery = recover_before_requested_restore(
            plan,
            &pending,
            &displaced.sha256,
            &mut arm,
            run_systemctl,
            verify_health,
        );
        return Err(combine_errors(
            "reserve capacity for explicit systemd rollback",
            &error,
            recovery.err(),
        ));
    }
    update_recovery_phase(plan, &mut arm, RecoveryPhase::RollbackReady)?;
    execute_requested_rollback(
        plan,
        RollbackExecution {
            previous_path,
            restored_manifest,
            restored,
            displaced,
            transaction_id,
            pending,
            displaced_manifest,
            arm,
        },
        &lifecycle,
        run_systemctl,
        verify_health,
    )
}

fn prepare_rollback_lifecycle<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<ClaimedLifecycle, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    plan.validate()?;
    let locked = acquire_with_trusted_controller(plan, || {
        LockedLifecycle::acquire(plan.transaction_root()?, &plan.unit, &plan.store_path)
    })?;
    let bind_mode = if load_recovery_arm(&plan.store_path)?.is_some() {
        BindMode::ExistingOnly
    } else {
        BindMode::LegacyOperationOrMatch
    };
    let mut lifecycle = locked.bind(&plan.binary_path, bind_mode, run_systemctl)?;
    if !lifecycle.claim_is_persisted() {
        validate_managed_unit_contract(plan, run_systemctl)?;
        lifecycle.persist_claim(run_systemctl)?;
    }
    recover_before_operation(plan, &lifecycle, run_systemctl, verify_health)?;
    validate_managed_unit_contract(plan, run_systemctl)?;
    validate_restore_filesystems(plan)?;
    Ok(lifecycle)
}

struct RollbackExecution {
    previous_path: PathBuf,
    restored_manifest: GenerationManifest,
    restored: RemoteSystemdArtifact,
    displaced: RemoteSystemdArtifact,
    transaction_id: String,
    pending: PathBuf,
    displaced_manifest: GenerationManifest,
    arm: RecoveryArm,
}

fn execute_requested_rollback<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    mut context: RollbackExecution,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdRollbackReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let expected_database = context.restored_manifest.database_seal()?;
    let rollback = restore_generation(
        plan,
        &context.previous_path,
        &context.restored_manifest,
        lifecycle,
        run_systemctl,
    )
    .and_then(|()| {
        reserve_generation_restore_capacity(plan, &context.pending, &context.displaced_manifest)
    })
    .and_then(|()| start_and_verify(plan, &context.restored.sha256, run_systemctl, verify_health));
    match rollback {
        Ok(_) => match seal_and_reverify_target(
            plan,
            &mut context.arm,
            &context.restored.sha256,
            Some(expected_database),
            run_systemctl,
            verify_health,
        ) {
            Ok(health) => commit_requested_rollback(plan, context, health, run_systemctl),
            Err(error) => Ok(recover_requested_rollback(
                plan,
                context,
                &error,
                lifecycle,
                run_systemctl,
                verify_health,
            )),
        },
        Err(error) => Ok(recover_requested_rollback(
            plan,
            context,
            &error,
            lifecycle,
            run_systemctl,
            verify_health,
        )),
    }
}

fn commit_requested_rollback<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    mut context: RollbackExecution,
    health: RemoteSystemdHealthReport,
    run_systemctl: &RunSystemctl,
) -> Result<RemoteSystemdRollbackReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    update_recovery_phase(plan, &mut context.arm, RecoveryPhase::Committing)?;
    swap_previous_with_pending(plan)?;
    finish_recovery_automation(plan, &context.arm, run_systemctl)?;
    Ok(RemoteSystemdRollbackReport {
        report_version: MANIFEST_VERSION,
        operation: "rollback_systemd".to_string(),
        transaction_id: context.transaction_id,
        unit: plan.unit.clone(),
        outcome: RemoteSystemdUpgradeOutcome::RolledBack,
        restored: context.restored,
        displaced: context.displaced,
        database_schema_restored: context.restored_manifest.database_schema,
        backup_path: plan.previous_path(),
        health: Some(health),
        error: None,
        recovery_error: None,
    })
}

fn recover_requested_rollback<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    mut context: RollbackExecution,
    rollback_error: &CliError,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> RemoteSystemdRollbackReport
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let recovery = restore_generation(
        plan,
        &context.pending,
        &context.displaced_manifest,
        lifecycle,
        run_systemctl,
    )
    .and_then(|()| update_recovery_phase(plan, &mut context.arm, RecoveryPhase::RollbackFinalizing))
    .and_then(|()| remove_tree_if_exists(&context.pending))
    .and_then(|()| sync_directory(&plan.store_path))
    .and_then(|()| {
        restart_existing_service(
            plan,
            &context.displaced_manifest.binary_sha256,
            run_systemctl,
            verify_health,
        )
    });
    match recovery {
        Ok(health) => {
            let finalization = finish_recovery_automation(plan, &context.arm, run_systemctl);
            failed_rollback_report(
                plan,
                context,
                Some(health),
                rollback_error,
                finalization.err().as_ref(),
            )
        }
        Err(recovery_error) => {
            failed_rollback_report(plan, context, None, rollback_error, Some(&recovery_error))
        }
    }
}

fn failed_rollback_report(
    plan: &RemoteSystemdOperationPlan,
    context: RollbackExecution,
    health: Option<RemoteSystemdHealthReport>,
    rollback_error: &CliError,
    recovery_error: Option<&CliError>,
) -> RemoteSystemdRollbackReport {
    RemoteSystemdRollbackReport {
        report_version: MANIFEST_VERSION,
        operation: "rollback_systemd".to_string(),
        transaction_id: context.transaction_id,
        unit: plan.unit.clone(),
        outcome: RemoteSystemdUpgradeOutcome::RollbackFailed,
        restored: context.restored,
        displaced: context.displaced,
        database_schema_restored: context.restored_manifest.database_schema,
        backup_path: context.previous_path,
        health,
        error: Some(rollback_error.to_string()),
        recovery_error: recovery_error.map(ToString::to_string),
    }
}

fn recover_before_requested_restore<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    pending: &Path,
    displaced_sha256: &str,
    arm: &mut super::model::RecoveryArm,
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
    update_recovery_phase(plan, arm, RecoveryPhase::RollbackFinalizing)?;
    remove_tree_if_exists(pending)?;
    sync_directory(&plan.store_path)?;
    restart_existing_service(plan, displaced_sha256, run_systemctl, verify_health)?;
    finish_recovery_automation(plan, arm, run_systemctl)
}
