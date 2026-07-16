use std::path::Path;

use crate::errors::CliError;

use super::super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::super::automation::{finish_recovery_automation, update_recovery_phase};
use super::super::database::verify_live_database_seal;
use super::super::files::{combine_errors, io_error};
use super::super::generation::{load_manifest, preflight_generation, restart_existing_service};
use super::super::generation_restore::restore_generation_retaining_current;
use super::super::model::{
    GenerationManifest, RecoveryArm, RecoveryPhase, RemoteSystemdHealthReport,
    RemoteSystemdOperationPlan, RemoteSystemdRecoveryOutcome, RemoteSystemdRecoveryReport,
};
use super::super::ownership::ClaimedLifecycle;
use super::super::systemd::start_and_verify;
use super::{recovery_report, verify_installed_sha};

pub(super) fn finish_committed<RunSystemctl, VerifyHealth>(
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
    let previous_path = plan.previous_path();
    let manifest = load_manifest(&previous_path)?;
    if manifest.transaction_id != arm.transaction_id {
        return Err(io_error(format!(
            "committed generation does not match transaction {}",
            arm.transaction_id
        )));
    }
    if manifest.binary_sha256 != arm.before_sha256 {
        return Err(io_error(format!(
            "committed fallback generation digest does not match transaction {}",
            arm.transaction_id
        )));
    }
    preflight_generation(plan, &previous_path, &manifest)?;
    match validate_committed_target(plan, arm, run_systemctl, verify_health) {
        Ok(()) => {
            finish_recovery_automation(plan, arm, run_systemctl)?;
            Ok(recovery_report(
                arm,
                RemoteSystemdRecoveryOutcome::CommitCompleted,
                "completed enablement after the durable generation commit",
            ))
        }
        Err(target_error) => {
            let fallback = CommittedFallback {
                plan,
                arm,
                previous_path: &previous_path,
                manifest: &manifest,
                lifecycle,
            };
            restore_previous_generation(&fallback, &target_error, run_systemctl, verify_health)
        }
    }
}

fn validate_committed_target<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    arm: &RecoveryArm,
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
    let seal = arm.target_database_seal.ok_or_else(|| {
        io_error(format!(
            "committing systemd transaction {} has no target database seal",
            arm.transaction_id
        ))
    })?;
    verify_installed_sha(plan, &arm.target_sha256)?;
    verify_live_database_seal(&plan.state_path, seal)?;
    start_and_verify(plan, &arm.target_sha256, run_systemctl, verify_health)?;
    verify_live_database_seal(&plan.state_path, seal)
}

struct CommittedFallback<'a> {
    plan: &'a RemoteSystemdOperationPlan,
    arm: &'a RecoveryArm,
    previous_path: &'a Path,
    manifest: &'a GenerationManifest,
    lifecycle: &'a ClaimedLifecycle,
}

fn restore_previous_generation<RunSystemctl, VerifyHealth>(
    context: &CommittedFallback<'_>,
    target_error: &CliError,
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
    let mut fallback_arm = context.arm.clone();
    let failed_state_path = context
        .plan
        .failed_current_state_path(&context.arm.transaction_id);
    let recovery = restore_generation_retaining_current(
        context.plan,
        context.previous_path,
        context.manifest,
        &failed_state_path,
        context.lifecycle,
        run_systemctl,
    )
    .and_then(|()| {
        update_recovery_phase(
            context.plan,
            &mut fallback_arm,
            RecoveryPhase::RollbackFinalizing,
        )
    })
    .and_then(|()| {
        restart_existing_service(
            context.plan,
            &context.arm.before_sha256,
            run_systemctl,
            verify_health,
        )
    })
    .and_then(|_| finish_recovery_automation(context.plan, &fallback_arm, run_systemctl));
    if let Err(fallback_error) = recovery {
        return Err(combine_errors(
            "restore retained generation after committed target failure",
            target_error,
            Some(fallback_error),
        ));
    }
    Ok(recovery_report(
        context.arm,
        RemoteSystemdRecoveryOutcome::RolledBack,
        format!(
            "restored the retained pre-transaction generation after committed target validation failed: {target_error}"
        ),
    ))
}
