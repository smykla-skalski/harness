use std::io::ErrorKind;
use std::path::Path;

use fs_err as fs;

use crate::errors::CliError;

use super::files::{io_error, sha256_file};
use super::model::{
    ENVIRONMENT_FILE, GenerationManifest, RemoteSystemdOperationPlan, STATE_DIRECTORY, UNIT_FILE,
};
use super::state::state_tree_sha256;

pub(super) struct GenerationDigests {
    pub(super) unit: Option<String>,
    pub(super) environment: Option<String>,
    pub(super) state: Option<String>,
}

pub(super) fn generation_digests(
    generation_path: &Path,
    unit_present: bool,
    environment_present: bool,
    state_present: bool,
) -> Result<GenerationDigests, CliError> {
    let state = state_tree_sha256(&generation_path.join(STATE_DIRECTORY))?;
    if state.is_some() != state_present {
        return Err(io_error("snapshot state presence changed while hashing"));
    }
    Ok(GenerationDigests {
        unit: required_optional_digest(&generation_path.join(UNIT_FILE), unit_present)?,
        environment: required_optional_digest(
            &generation_path.join(ENVIRONMENT_FILE),
            environment_present,
        )?,
        state,
    })
}

pub(super) fn verify_generation_integrity(
    generation_path: &Path,
    manifest: &GenerationManifest,
) -> Result<(), CliError> {
    require_presence_consistency(manifest)?;
    verify_optional_digest(
        &generation_path.join(UNIT_FILE),
        manifest.unit_sha256.as_deref(),
        "unit",
    )?;
    verify_optional_digest(
        &generation_path.join(ENVIRONMENT_FILE),
        manifest.environment_sha256.as_deref(),
        "environment",
    )?;
    verify_state_digest(
        &generation_path.join(STATE_DIRECTORY),
        manifest.state_sha256.as_deref(),
    )
}

pub(super) fn installed_binary_matches(
    plan: &RemoteSystemdOperationPlan,
    manifest: &GenerationManifest,
) -> bool {
    installed_file_matches(&plan.binary_path, Some(&manifest.binary_sha256))
}

pub(super) fn installed_unit_matches(
    plan: &RemoteSystemdOperationPlan,
    manifest: &GenerationManifest,
) -> bool {
    installed_file_matches(&plan.unit_path, manifest.unit_sha256.as_ref())
}

pub(super) fn installed_environment_matches(
    plan: &RemoteSystemdOperationPlan,
    manifest: &GenerationManifest,
) -> bool {
    installed_file_matches(&plan.environment_path, manifest.environment_sha256.as_ref())
}

pub(super) fn installed_state_matches(
    plan: &RemoteSystemdOperationPlan,
    manifest: &GenerationManifest,
) -> bool {
    state_tree_sha256(&plan.state_path).is_ok_and(|digest| digest == manifest.state_sha256)
}

pub(super) fn verify_installed_generation(
    plan: &RemoteSystemdOperationPlan,
    manifest: &GenerationManifest,
) -> Result<(), CliError> {
    for (matches, label, path) in [
        (
            installed_binary_matches(plan, manifest),
            "binary",
            &plan.binary_path,
        ),
        (
            installed_unit_matches(plan, manifest),
            "unit",
            &plan.unit_path,
        ),
        (
            installed_environment_matches(plan, manifest),
            "environment",
            &plan.environment_path,
        ),
        (
            installed_state_matches(plan, manifest),
            "state",
            &plan.state_path,
        ),
    ] {
        if !matches {
            return Err(io_error(format!(
                "restored systemd {label} does not match its manifest: {}",
                path.display()
            )));
        }
    }
    Ok(())
}

fn installed_file_matches(path: &Path, expected: Option<&String>) -> bool {
    optional_file_digest(path).is_ok_and(|digest| digest.as_ref() == expected)
}

fn require_presence_consistency(manifest: &GenerationManifest) -> Result<(), CliError> {
    if manifest.unit_metadata.is_some() != manifest.unit_sha256.is_some()
        || manifest.environment_metadata.is_some() != manifest.environment_sha256.is_some()
        || manifest.state_present != manifest.state_sha256.is_some()
    {
        Err(io_error(
            "rollback manifest metadata and content digest presence disagree",
        ))
    } else {
        Ok(())
    }
}

fn required_optional_digest(path: &Path, expected: bool) -> Result<Option<String>, CliError> {
    let digest = optional_file_digest(path)?;
    if digest.is_some() == expected {
        Ok(digest)
    } else {
        Err(io_error(format!(
            "snapshot artifact presence changed while hashing: {}",
            path.display()
        )))
    }
}

fn verify_optional_digest(
    path: &Path,
    expected: Option<&str>,
    label: &str,
) -> Result<(), CliError> {
    let observed = optional_file_digest(path)?;
    match (observed.as_deref(), expected) {
        (None, None) => Ok(()),
        (None, Some(_)) => Err(io_error(format!(
            "retained {label} artifact is missing: {}",
            path.display()
        ))),
        (Some(_), None) => Err(io_error(format!(
            "retained {label} artifact exists but the manifest records it absent: {}",
            path.display()
        ))),
        (Some(observed), Some(expected)) if observed == expected => Ok(()),
        _ => Err(io_error(format!(
            "retained {label} content digest mismatch for {}: expected {expected:?}, found {observed:?}",
            path.display()
        ))),
    }
}

fn verify_state_digest(path: &Path, expected: Option<&str>) -> Result<(), CliError> {
    let observed = state_tree_sha256(path)?;
    if observed.as_deref() == expected {
        Ok(())
    } else {
        Err(io_error(format!(
            "retained state content digest mismatch for {}: expected {expected:?}, found {observed:?}",
            path.display()
        )))
    }
}

fn optional_file_digest(path: &Path) -> Result<Option<String>, CliError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err(io_error(format!(
                "rollback artifact is not a regular file: {}",
                path.display()
            )))
        }
        Ok(_) => sha256_file(path).map(Some),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io_error(format!(
            "inspect rollback artifact {}: {error}",
            path.display()
        ))),
    }
}
