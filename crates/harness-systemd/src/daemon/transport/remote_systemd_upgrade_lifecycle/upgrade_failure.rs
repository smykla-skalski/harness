use std::path::PathBuf;

use fs_err as fs;

use crate::errors::CliError;

use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::automation::{finish_recovery_automation, update_recovery_phase};
use super::generation::{
    reconcile_rotation_state, restart_existing_service, retain_failed_generation,
    transaction_generation_path,
};
use super::generation_restore::restore_generation_retaining_current;
use super::model::{
    GenerationManifest, MANIFEST_VERSION, RecoveryArm, RecoveryPhase, RemoteSystemdArtifact,
    RemoteSystemdHealthReport, RemoteSystemdOperationPlan, RemoteSystemdUpgradeOutcome,
    RemoteSystemdUpgradeReport,
};
use super::ownership::ClaimedLifecycle;

pub(super) struct FailedUpgradeContext<'a> {
    pub(super) operation: &'a RemoteSystemdOperationPlan,
    pub(super) generation_path: PathBuf,
    pub(super) transaction_id: String,
    pub(super) previous: RemoteSystemdArtifact,
    pub(super) candidate: RemoteSystemdArtifact,
    pub(super) manifest: &'a GenerationManifest,
    pub(super) arm: RecoveryArm,
    pub(super) error: CliError,
}

pub(super) fn recover_commit_failure<RunSystemctl, VerifyHealth>(
    context: FailedUpgradeContext<'_>,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> RemoteSystemdUpgradeReport
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let generation = transaction_generation_path(context.operation, &context.transaction_id);
    match generation {
        Ok(generation_path) => rollback_failed_upgrade(
            FailedUpgradeContext {
                generation_path,
                ..context
            },
            lifecycle,
            run_systemctl,
            verify_health,
        ),
        Err(location_error) => rollback_unavailable_report(&context, &location_error),
    }
}

pub(super) fn rollback_failed_upgrade<RunSystemctl, VerifyHealth>(
    mut context: FailedUpgradeContext<'_>,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> RemoteSystemdUpgradeReport
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let failed_state_path = context
        .operation
        .failed_current_state_path(&context.transaction_id);
    if let Err(error) = restore_generation_retaining_current(
        context.operation,
        &context.generation_path,
        context.manifest,
        &failed_state_path,
        lifecycle,
        run_systemctl,
    ) {
        return rollback_failed_report(context, &error, None);
    }
    let backup_path = match retain_restored_generation(&mut context) {
        Ok(path) => path,
        Err(error) => return rollback_failed_report(context, &error, None),
    };
    context.generation_path.clone_from(&backup_path);
    let health = match restart_existing_service(
        context.operation,
        &context.manifest.binary_sha256,
        run_systemctl,
        verify_health,
    ) {
        Ok(health) => health,
        Err(error) => return rollback_failed_report(context, &error, None),
    };
    let finalized = finish_recovery_automation(context.operation, &context.arm, run_systemctl)
        .map(|()| backup_path);
    rollback_result(context, health, finalized)
}

fn retain_restored_generation(context: &mut FailedUpgradeContext<'_>) -> Result<PathBuf, CliError> {
    update_recovery_phase(
        context.operation,
        &mut context.arm,
        RecoveryPhase::RollbackFinalizing,
    )?;
    retain_rollback_generation(context)
}

fn retain_rollback_generation(context: &FailedUpgradeContext<'_>) -> Result<PathBuf, CliError> {
    if context.generation_path == context.operation.pending_path() {
        retain_failed_generation(context.operation, &context.transaction_id)
    } else {
        reconcile_rotation_state(context.operation)?;
        Ok(context.generation_path.clone())
    }
}

fn rollback_result(
    context: FailedUpgradeContext<'_>,
    health: RemoteSystemdHealthReport,
    finalized: Result<PathBuf, CliError>,
) -> RemoteSystemdUpgradeReport {
    let failed_state_path = retained_failed_state_path(&context);
    match finalized {
        Ok(backup_path) => RemoteSystemdUpgradeReport {
            report_version: MANIFEST_VERSION,
            operation: "upgrade_systemd".to_string(),
            transaction_id: context.transaction_id,
            unit: context.operation.unit.clone(),
            outcome: RemoteSystemdUpgradeOutcome::RolledBack,
            changed: false,
            previous: context.previous,
            candidate: context.candidate,
            database_schema_before: context.manifest.database_schema,
            backup_path: Some(backup_path),
            failed_state_path,
            health: Some(health),
            error: Some(context.error.to_string()),
            rollback_error: None,
        },
        Err(error) => rollback_failed_report(context, &error, Some(health)),
    }
}

fn rollback_failed_report(
    context: FailedUpgradeContext<'_>,
    rollback_error: &CliError,
    health: Option<RemoteSystemdHealthReport>,
) -> RemoteSystemdUpgradeReport {
    let failed_state_path = retained_failed_state_path(&context);
    RemoteSystemdUpgradeReport {
        report_version: MANIFEST_VERSION,
        operation: "upgrade_systemd".to_string(),
        transaction_id: context.transaction_id,
        unit: context.operation.unit.clone(),
        outcome: RemoteSystemdUpgradeOutcome::RollbackFailed,
        changed: health.is_none(),
        previous: context.previous,
        candidate: context.candidate,
        database_schema_before: context.manifest.database_schema,
        backup_path: Some(context.generation_path),
        failed_state_path,
        health,
        error: Some(context.error.to_string()),
        rollback_error: Some(rollback_error.to_string()),
    }
}

fn rollback_unavailable_report(
    context: &FailedUpgradeContext<'_>,
    location_error: &CliError,
) -> RemoteSystemdUpgradeReport {
    let pending = context.operation.pending_path();
    let backup_path = pending.exists().then_some(pending).or_else(|| {
        context
            .operation
            .previous_path()
            .exists()
            .then(|| context.operation.previous_path())
    });
    RemoteSystemdUpgradeReport {
        report_version: MANIFEST_VERSION,
        operation: "upgrade_systemd".to_string(),
        transaction_id: context.transaction_id.clone(),
        unit: context.operation.unit.clone(),
        outcome: RemoteSystemdUpgradeOutcome::RollbackFailed,
        changed: true,
        previous: context.previous.clone(),
        candidate: context.candidate.clone(),
        database_schema_before: context.manifest.database_schema,
        backup_path,
        failed_state_path: retained_failed_state_path(context),
        health: None,
        error: Some(context.error.to_string()),
        rollback_error: Some(location_error.to_string()),
    }
}

fn retained_failed_state_path(context: &FailedUpgradeContext<'_>) -> Option<PathBuf> {
    let path = context
        .operation
        .failed_current_state_path(&context.transaction_id);
    fs::symlink_metadata(&path).ok().map(|_| path)
}
