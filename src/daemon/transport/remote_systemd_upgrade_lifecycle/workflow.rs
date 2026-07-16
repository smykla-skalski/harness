use std::path::{Path, PathBuf};

use uuid::Uuid;

use crate::errors::CliError;

use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::automation::{
    arm_recovery_automation, finish_recovery_automation, load_recovery_arm, update_recovery_phase,
};
use super::binary::{acquire_with_trusted_controller, inspect_binary};
use super::capacity::{reserve_generation_restore_capacity, validate_restore_filesystems};
use super::files::{
    combine_errors, copy_file_atomic, create_private_directory, io_error, remove_file_if_exists,
    remove_tree_if_exists, sha256_file, sync_directory, validate_candidate,
};
use super::generation::{
    activate_candidate, promote_pending_generation, restart_existing_service, snapshot_generation,
};
use super::model::{
    CANDIDATE_FILE, FileMetadata, GenerationManifest, MANIFEST_VERSION, RecoveryArm,
    RecoveryOperation, RecoveryPhase, RemoteSystemdArtifact, RemoteSystemdHealthReport,
    RemoteSystemdOperationPlan, RemoteSystemdUpgradeOutcome, RemoteSystemdUpgradePlan,
    RemoteSystemdUpgradeReport,
};
use super::ownership::{BindMode, ClaimedLifecycle, LockedLifecycle};
use super::recovery::recover_before_operation;
use super::systemd::{stop_and_inhibit, unit_requires_notify_upgrade};
use super::target_database::seal_and_reverify_target;
use super::unit_contract::validate_managed_unit_contract;
use super::upgrade_failure::{
    FailedUpgradeContext, recover_commit_failure, rollback_failed_upgrade,
};

pub(crate) fn upgrade_remote_systemd_with<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdUpgradePlan,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdUpgradeReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    plan.operation.validate()?;
    let locked = acquire_with_trusted_controller(&plan.operation, || {
        LockedLifecycle::acquire(
            plan.operation.transaction_root()?,
            &plan.operation.unit,
            &plan.operation.store_path,
        )
    })?;
    let bind_mode = if load_recovery_arm(&plan.operation.store_path)?.is_some() {
        BindMode::ExistingOnly
    } else {
        BindMode::LegacyOperationOrMatch
    };
    let mut lifecycle = locked.bind(&plan.operation.binary_path, bind_mode, run_systemctl)?;
    if !lifecycle.claim_is_persisted() {
        validate_managed_unit_contract(&plan.operation, run_systemctl)?;
        lifecycle.persist_claim(run_systemctl)?;
    }
    recover_before_operation(&plan.operation, &lifecycle, run_systemctl, verify_health)?;
    validate_managed_unit_contract(&plan.operation, run_systemctl)?;
    validate_restore_filesystems(&plan.operation)?;
    let installed_sha256 = sha256_file(&plan.operation.binary_path)?;
    verify_health(&plan.operation, &installed_sha256, run_systemctl)?;
    validate_candidate(&plan.candidate_path)?;

    let staged = stage_upgrade_candidate(plan)?;
    let readiness_change = unit_requires_notify_upgrade(&plan.operation.unit_path)?;
    if staged.candidate_sha256 == staged.previous.sha256 && !readiness_change {
        return health_checked_noop(&plan.operation, staged, run_systemctl, verify_health);
    }
    run_changed_upgrade(
        &plan.operation,
        staged,
        &lifecycle,
        run_systemctl,
        verify_health,
    )
}

struct StagedUpgrade {
    pending_path: PathBuf,
    transaction_id: String,
    candidate_path: PathBuf,
    candidate_sha256: String,
    previous: RemoteSystemdArtifact,
}

struct UpgradeActivation<'a> {
    staged: StagedUpgrade,
    candidate: RemoteSystemdArtifact,
    manifest: &'a GenerationManifest,
    arm: RecoveryArm,
}

impl<'a> UpgradeActivation<'a> {
    fn into_failed_upgrade(
        self,
        operation: &'a RemoteSystemdOperationPlan,
        error: CliError,
    ) -> FailedUpgradeContext<'a> {
        FailedUpgradeContext {
            operation,
            generation_path: self.staged.pending_path,
            transaction_id: self.staged.transaction_id,
            previous: self.staged.previous,
            candidate: self.candidate,
            manifest: self.manifest,
            arm: self.arm,
            error,
        }
    }
}

fn stage_upgrade_candidate(plan: &RemoteSystemdUpgradePlan) -> Result<StagedUpgrade, CliError> {
    let pending_path = plan.operation.pending_path();
    create_private_directory(&pending_path)?;
    let transaction_id = Uuid::new_v4().simple().to_string();
    let candidate_path = pending_path.join(CANDIDATE_FILE);
    copy_file_atomic(
        &plan.candidate_path,
        &candidate_path,
        FileMetadata::private_executable(),
    )?;
    let candidate_sha256 = sha256_file(&candidate_path)?;
    let previous = inspect_binary(&plan.operation.binary_path, &plan.operation.binary_path)?;
    Ok(StagedUpgrade {
        pending_path,
        transaction_id,
        candidate_path,
        candidate_sha256,
        previous,
    })
}

fn health_checked_noop<RunSystemctl, VerifyHealth>(
    operation: &RemoteSystemdOperationPlan,
    staged: StagedUpgrade,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdUpgradeReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let candidate = RemoteSystemdArtifact {
        version: staged.previous.version.clone(),
        sha256: staged.candidate_sha256,
        binary_path: operation.binary_path.clone(),
    };
    remove_tree_if_exists(&staged.pending_path)?;
    let health = verify_health(operation, &staged.previous.sha256, run_systemctl)?;
    Ok(RemoteSystemdUpgradeReport {
        report_version: MANIFEST_VERSION,
        operation: "upgrade_systemd".to_string(),
        transaction_id: staged.transaction_id,
        unit: operation.unit.clone(),
        outcome: RemoteSystemdUpgradeOutcome::Noop,
        changed: false,
        previous: staged.previous,
        candidate,
        database_schema_before: None,
        backup_path: operation
            .previous_path()
            .exists()
            .then(|| operation.previous_path()),
        failed_state_path: None,
        health: Some(health),
        error: None,
        rollback_error: None,
    })
}

fn run_changed_upgrade<RunSystemctl, VerifyHealth>(
    operation: &RemoteSystemdOperationPlan,
    staged: StagedUpgrade,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdUpgradeReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let mut arm = arm_recovery_automation(
        operation,
        &operation.controller_path,
        &staged.transaction_id,
        RecoveryOperation::Upgrade,
        &staged.previous.sha256,
        &staged.candidate_sha256,
        run_systemctl,
    )?;
    let manifest = match stop_and_snapshot(operation, &staged, run_systemctl) {
        Ok(manifest) => manifest,
        Err(error) => {
            let recovery = recover_snapshot_failure(
                operation,
                &staged,
                &mut arm,
                run_systemctl,
                verify_health,
            );
            return Err(combine_errors(
                "snapshot systemd rollback generation",
                &error,
                recovery.err(),
            ));
        }
    };
    if let Err(error) =
        reserve_generation_restore_capacity(operation, &staged.pending_path, &manifest)
    {
        let recovery =
            recover_snapshot_failure(operation, &staged, &mut arm, run_systemctl, verify_health);
        return Err(combine_errors(
            "reserve systemd rollback capacity",
            &error,
            recovery.err(),
        ));
    }
    update_recovery_phase(operation, &mut arm, RecoveryPhase::RollbackReady)?;
    let candidate = match inspect_staged_candidate(operation, &staged) {
        Ok(candidate) => candidate,
        Err(error) => {
            return Ok(rollback_failed_upgrade(
                FailedUpgradeContext {
                    operation,
                    generation_path: staged.pending_path,
                    transaction_id: staged.transaction_id,
                    previous: staged.previous,
                    candidate: unverified_candidate(
                        staged.candidate_sha256,
                        &operation.binary_path,
                    ),
                    manifest: &manifest,
                    arm,
                    error,
                },
                lifecycle,
                run_systemctl,
                verify_health,
            ));
        }
    };
    activate_and_commit(
        operation,
        UpgradeActivation {
            staged,
            candidate,
            manifest: &manifest,
            arm,
        },
        lifecycle,
        run_systemctl,
        verify_health,
    )
}

fn stop_and_snapshot<RunSystemctl>(
    operation: &RemoteSystemdOperationPlan,
    staged: &StagedUpgrade,
    run_systemctl: &RunSystemctl,
) -> Result<GenerationManifest, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    stop_and_inhibit(operation, run_systemctl)?;
    snapshot_generation(
        operation,
        &staged.pending_path,
        &staged.transaction_id,
        &staged.previous,
    )
}

fn recover_snapshot_failure<RunSystemctl, VerifyHealth>(
    operation: &RemoteSystemdOperationPlan,
    staged: &StagedUpgrade,
    arm: &mut RecoveryArm,
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
    update_recovery_phase(operation, arm, RecoveryPhase::RollbackFinalizing)?;
    restart_existing_service(
        operation,
        &staged.previous.sha256,
        run_systemctl,
        verify_health,
    )?;
    remove_tree_if_exists(&staged.pending_path)?;
    sync_directory(&operation.store_path)?;
    finish_recovery_automation(operation, arm, run_systemctl)
}

fn inspect_staged_candidate(
    operation: &RemoteSystemdOperationPlan,
    staged: &StagedUpgrade,
) -> Result<RemoteSystemdArtifact, CliError> {
    let candidate = inspect_binary(&staged.candidate_path, &operation.binary_path)?;
    if candidate.sha256 == staged.candidate_sha256 {
        Ok(candidate)
    } else {
        Err(io_error(format!(
            "candidate changed while verifying its staged digest: expected {}, found {}",
            staged.candidate_sha256, candidate.sha256
        )))
    }
}

fn activate_and_commit<'a, RunSystemctl, VerifyHealth>(
    operation: &'a RemoteSystemdOperationPlan,
    mut context: UpgradeActivation<'a>,
    lifecycle: &ClaimedLifecycle,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdUpgradeReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    let activation = activate_candidate(
        operation,
        &context.staged.candidate_path,
        &context.staged.candidate_sha256,
        lifecycle,
        run_systemctl,
        verify_health,
    );
    if let Err(error) = activation {
        return Ok(rollback_failed_upgrade(
            context.into_failed_upgrade(operation, error),
            lifecycle,
            run_systemctl,
            verify_health,
        ));
    }
    let health = match seal_and_reverify_target(
        operation,
        &mut context.arm,
        &context.staged.candidate_sha256,
        None,
        run_systemctl,
        verify_health,
    ) {
        Ok(health) => health,
        Err(error) => {
            return Ok(rollback_failed_upgrade(
                context.into_failed_upgrade(operation, error),
                lifecycle,
                run_systemctl,
                verify_health,
            ));
        }
    };
    let committed = remove_file_if_exists(&context.staged.candidate_path)
        .and_then(|()| {
            update_recovery_phase(operation, &mut context.arm, RecoveryPhase::Committing)
        })
        .and_then(|()| promote_pending_generation(operation));
    match committed {
        Ok(previous_path) => {
            finish_recovery_automation(operation, &context.arm, run_systemctl)?;
            Ok(RemoteSystemdUpgradeReport {
                report_version: MANIFEST_VERSION,
                operation: "upgrade_systemd".to_string(),
                transaction_id: context.staged.transaction_id,
                unit: operation.unit.clone(),
                outcome: RemoteSystemdUpgradeOutcome::Upgraded,
                changed: true,
                previous: context.staged.previous,
                candidate: context.candidate,
                database_schema_before: context.manifest.database_schema,
                backup_path: Some(previous_path),
                failed_state_path: None,
                health: Some(health),
                error: None,
                rollback_error: None,
            })
        }
        Err(error) => Ok(recover_commit_failure(
            context.into_failed_upgrade(operation, error),
            lifecycle,
            run_systemctl,
            verify_health,
        )),
    }
}

fn unverified_candidate(sha256: String, binary_path: &Path) -> RemoteSystemdArtifact {
    RemoteSystemdArtifact {
        version: "not executed; staged digest verification failed".to_string(),
        sha256,
        binary_path: binary_path.to_path_buf(),
    }
}
