use std::path::Path;

use crate::errors::CliError;

use super::super::files::{io_error, sha256_file};
use super::super::model::{
    LEGACY_RECOVERY_ARM_VERSION, RECOVERY_ARM_VERSION, RecoveryArm, RemoteSystemdOperationPlan,
};
use super::ReleasePairRecord;

pub(super) fn validate_arm_controller_binding(
    record: &ReleasePairRecord,
    arm: &RecoveryArm,
) -> Result<(), CliError> {
    match (arm.arm_version, arm.controller_sha256.as_deref()) {
        (RECOVERY_ARM_VERSION, Some(digest)) if digest == record.controller_sha256 => Ok(()),
        (RECOVERY_ARM_VERSION, Some(digest)) => Err(io_error(format!(
            "armed controller digest does not match the root-owned release pair: expected {}, found {digest}",
            record.controller_sha256
        ))),
        (LEGACY_RECOVERY_ARM_VERSION, None) => Ok(()),
        _ => Err(io_error(format!(
            "invalid controller binding in systemd recovery arm v{}",
            arm.arm_version
        ))),
    }
}

pub(super) fn verify_armed_controller_digest(
    arm: &RecoveryArm,
    controller: &Path,
) -> Result<(), CliError> {
    let Some(expected) = arm.controller_sha256.as_deref() else {
        return Ok(());
    };
    let observed = sha256_file(controller)?;
    if observed == expected {
        Ok(())
    } else {
        Err(io_error(format!(
            "immutable recovery controller digest does not match the armed controller: expected {expected}, found {observed}"
        )))
    }
}

pub(super) fn validate_armed_plan(
    expected: &RemoteSystemdOperationPlan,
    arm: &RecoveryArm,
) -> Result<(), CliError> {
    let actual = arm.plan()?;
    if actual.unit == expected.unit
        && actual.binary_path == expected.binary_path
        && actual.unit_path == expected.unit_path
        && actual.environment_path == expected.environment_path
        && actual.state_path == expected.state_path
        && actual.store_path == expected.store_path
    {
        Ok(())
    } else {
        Err(io_error(format!(
            "armed systemd transaction paths do not match unit {}",
            expected.unit
        )))
    }
}
