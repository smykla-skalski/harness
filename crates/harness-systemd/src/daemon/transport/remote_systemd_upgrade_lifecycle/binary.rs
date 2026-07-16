use std::path::Path;

use crate::errors::CliError;

use super::files::{regular_file_metadata, sha256_file};
use super::model::RemoteSystemdArtifact;
use super::model::RemoteSystemdOperationPlan;
use super::release_pair;

pub(super) fn verify_trusted_controller(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    release_pair::verify_trusted_controller(plan)
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
