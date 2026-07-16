use crate::errors::CliError;

use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::automation::record_target_database_seal;
use super::database::{seal_live_database_state, verify_live_database_seal};
use super::files::io_error;
use super::model::{
    DatabaseSeal, RecoveryArm, RemoteSystemdHealthReport, RemoteSystemdOperationPlan,
};
use super::systemd::{start_and_verify, stop_and_inhibit};

pub(super) fn seal_and_reverify_target<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    arm: &mut RecoveryArm,
    target_sha256: &str,
    expected_database: Option<DatabaseSeal>,
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
    let seal = seal_live_database_state(&plan.state_path)?;
    if let Some(expected) = expected_database.filter(|expected| seal != *expected) {
        return Err(io_error(format!(
            "restored target database does not match its generation manifest: expected {expected:?}, found {seal:?}"
        )));
    }
    record_target_database_seal(plan, arm, seal)?;
    let health = start_and_verify(plan, target_sha256, run_systemctl, verify_health)?;
    verify_live_database_seal(&plan.state_path, seal)?;
    Ok(health)
}
