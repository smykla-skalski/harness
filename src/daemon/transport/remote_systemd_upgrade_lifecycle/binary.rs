use std::path::Path;

use crate::errors::CliError;

use super::files::{io_error, recovery_controller_sha256, regular_file_metadata, sha256_file};
use super::model::RemoteSystemdArtifact;
use super::model::RemoteSystemdOperationPlan;

pub(super) fn verify_trusted_controller(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    let controller_sha256 = recovery_controller_sha256(&plan.controller_path)?;
    let installed_sha256 = sha256_file(&plan.binary_path)?;
    if controller_sha256 == installed_sha256 {
        Ok(())
    } else {
        Err(io_error(format!(
            "systemd lifecycle coordinator digest does not match the installed binary; run the command with {} and pass the new executable through --candidate-path",
            plan.binary_path.display()
        )))
    }
}

pub(super) fn acquire_with_trusted_controller<Lock, Acquire>(
    plan: &RemoteSystemdOperationPlan,
    acquire: Acquire,
) -> Result<Lock, CliError>
where
    Acquire: FnOnce() -> Result<Lock, CliError>,
{
    verify_trusted_controller(plan)?;
    let lock = acquire()?;
    verify_trusted_controller(plan)?;
    Ok(lock)
}

pub(super) fn inspect_binary(
    source: &Path,
    reported_path: &Path,
) -> Result<RemoteSystemdArtifact, CliError> {
    regular_file_metadata(source)?;
    Ok(RemoteSystemdArtifact {
        version: "not executed during privileged lifecycle operation".to_string(),
        sha256: sha256_file(source)?,
        binary_path: reported_path.to_path_buf(),
    })
}
