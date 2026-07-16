use std::io::ErrorKind;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

use fs_err as fs;
use semver::Version;
use serde::{Deserialize, Serialize};

use crate::errors::CliError;

use super::super::remote_systemd_lifecycle::validate_canonical_unit_name;
use super::automation::load_recovery_arm;
use super::files::{
    create_private_directory, io_error, remove_file_if_exists, sha256_file, sync_directory,
    write_json_atomic,
};
use super::model::{
    LEGACY_RECOVERY_ARM_VERSION, PENDING_DIRECTORY, PREVIOUS_OLD_DIRECTORY, RECOVERY_ARM_FILE,
    RecoveryArm, RemoteSystemdOperationPlan,
};

#[path = "release_pair/armed.rs"]
mod armed;
#[path = "release_pair/trust.rs"]
mod trust;

use armed::{validate_arm_controller_binding, validate_armed_plan, verify_armed_controller_digest};
use trust::{canonical_path, trusted_uid, validate_trusted_executable};

const RELEASE_PAIR_FILE: &str = "controller.json";
const RELEASE_PAIR_RECORD_VERSION: u32 = 1;
pub(super) const LIFECYCLE_PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ReleasePairRecord {
    record_version: u32,
    lifecycle_protocol_version: u32,
    canonical_unit: String,
    daemon_path: PathBuf,
    daemon_sha256: String,
    controller_path: PathBuf,
    controller_sha256: String,
    release_identity: String,
}

pub(super) fn establish_locked_release_pair(
    unit: &str,
    daemon_path: &Path,
    controller_path: &Path,
    store_path: &Path,
) -> Result<(), CliError> {
    validate_canonical_unit_name(unit)?;
    create_private_directory(store_path)?;
    let daemon_path = validate_trusted_executable("daemon", daemon_path)?;
    let controller_path = validate_trusted_executable("controller", controller_path)?;
    let record = ReleasePairRecord {
        record_version: RELEASE_PAIR_RECORD_VERSION,
        lifecycle_protocol_version: LIFECYCLE_PROTOCOL_VERSION,
        canonical_unit: unit.to_string(),
        daemon_sha256: sha256_file(&daemon_path)?,
        daemon_path,
        controller_sha256: sha256_file(&controller_path)?,
        controller_path,
        release_identity: release_identity(),
    };
    record.validate_current()?;
    if let Some(existing) = load_record(store_path)? {
        ensure_pair_rotation_idle(store_path)?;
        if existing == record {
            return Ok(());
        }
        validate_idle_controller_rotation(&existing, &record)?;
    }
    write_record(store_path, &record)
}

#[cfg(test)]
pub(crate) fn establish_release_pair_for_tests(
    unit: &str,
    daemon_path: &Path,
    controller_path: &Path,
    store_path: &Path,
) -> Result<(), CliError> {
    establish_locked_release_pair(unit, daemon_path, controller_path, store_path)
}

pub(super) fn verify_trusted_controller(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    let record = load_required_record(&plan.store_path)?;
    record.validate_for(plan)?;
    verify_controller(&record, &plan.controller_path, true)?;
    let arm = load_recovery_arm(&plan.store_path)?;
    verify_daemon_digest(&record, plan, arm.as_ref())
}

pub(super) fn verify_recovery_controller(
    plan: &RemoteSystemdOperationPlan,
    arm: &RecoveryArm,
) -> Result<(), CliError> {
    let controller = recovery_controller_source(plan);
    match load_record(&plan.store_path)? {
        Some(record) => {
            record.validate_for(plan)?;
            validate_arm_controller_binding(&record, arm)?;
            verify_controller(&record, &controller, false)?;
            verify_armed_controller_digest(arm, &controller)?;
            let observed = sha256_file(&plan.binary_path)?;
            if observed == record.daemon_sha256
                || observed == arm.before_sha256
                || observed == arm.target_sha256
            {
                Ok(())
            } else {
                Err(io_error(format!(
                    "installed daemon digest is outside the armed release pair: {observed}"
                )))
            }
        }
        None => verify_legacy_armed_controller(plan, arm, &controller),
    }
}

pub(super) fn sync_armed_daemon_digest(
    plan: &RemoteSystemdOperationPlan,
    arm: &RecoveryArm,
) -> Result<(), CliError> {
    let Some(mut record) = load_record(&plan.store_path)? else {
        return Ok(());
    };
    record.validate_for(plan)?;
    validate_arm_controller_binding(&record, arm)?;
    verify_active_or_immutable_controller(&record, plan)?;
    let observed = sha256_file(&plan.binary_path)?;
    if observed != arm.before_sha256 && observed != arm.target_sha256 {
        return Err(io_error(format!(
            "installed daemon digest is outside transaction {} while finalizing the release pair: {observed}",
            arm.transaction_id
        )));
    }
    record.daemon_sha256 = observed;
    write_record(&plan.store_path, &record)
}

pub(in crate::daemon::transport) fn verify_uninstall_controller(
    unit: &str,
    controller_path: &Path,
    store_path: &Path,
) -> Result<(), CliError> {
    let Some(record) = load_record(store_path)? else {
        return Ok(());
    };
    record.validate_current()?;
    if record.canonical_unit != unit {
        return Err(io_error(format!(
            "release pair does not bind systemd unit {unit}"
        )));
    }
    verify_controller(&record, controller_path, true)?;
    verify_daemon_digest_at(&record, &record.daemon_path)
}

pub(in crate::daemon::transport) fn remove_release_pair(store_path: &Path) -> Result<(), CliError> {
    let path = record_path(store_path);
    remove_file_if_exists(&path)?;
    if store_path.exists() {
        sync_directory(store_path)?;
    }
    Ok(())
}

fn verify_legacy_armed_controller(
    plan: &RemoteSystemdOperationPlan,
    arm: &RecoveryArm,
    controller: &Path,
) -> Result<(), CliError> {
    if arm.arm_version != LEGACY_RECOVERY_ARM_VERSION {
        return Err(io_error(format!(
            "missing release pair for systemd recovery arm v{}",
            arm.arm_version
        )));
    }
    let immutable = plan.recovery_controller_path();
    let controller_sha256 = sha256_file(controller)?;
    let immutable_sha256 = sha256_file(&immutable)?;
    if controller_sha256 != immutable_sha256 || controller_sha256 != arm.before_sha256 {
        return Err(io_error(
            "legacy armed transaction recovery controller does not match its immutable pre-transaction daemon",
        ));
    }
    Ok(())
}

fn verify_controller(
    record: &ReleasePairRecord,
    configured_path: &Path,
    require_canonical_path: bool,
) -> Result<(), CliError> {
    let controller_path = validate_trusted_executable("controller", configured_path)?;
    let controller_sha256 = sha256_file(&controller_path)?;
    if controller_sha256 != record.controller_sha256 {
        return Err(io_error(format!(
            "systemd lifecycle controller digest does not match the root-owned release pair: expected {}, found {controller_sha256}",
            record.controller_sha256
        )));
    }
    if require_canonical_path && controller_path != record.controller_path {
        return Err(io_error(format!(
            "systemd lifecycle controller path does not match the root-owned release pair: expected {}, found {}",
            record.controller_path.display(),
            controller_path.display()
        )));
    }
    Ok(())
}

fn verify_active_or_immutable_controller(
    record: &ReleasePairRecord,
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    verify_controller(record, &plan.controller_path, false).or_else(|active_error| {
        verify_controller(record, &plan.recovery_controller_path(), false).map_err(
            |immutable_error| {
                io_error(format!(
                    "neither active nor immutable recovery controller matches the release pair: active={active_error}; immutable={immutable_error}"
                ))
            },
        )
    })
}

fn verify_daemon_digest(
    record: &ReleasePairRecord,
    plan: &RemoteSystemdOperationPlan,
    arm: Option<&RecoveryArm>,
) -> Result<(), CliError> {
    let daemon_path = validate_trusted_executable("daemon", &plan.binary_path)?;
    let observed = sha256_file(&daemon_path)?;
    if observed == record.daemon_sha256 {
        return Ok(());
    }
    if let Some(arm) = arm {
        validate_armed_plan(plan, arm)?;
        validate_arm_controller_binding(record, arm)?;
        if observed == arm.before_sha256 || observed == arm.target_sha256 {
            return Ok(());
        }
    }
    Err(io_error(format!(
        "installed daemon digest does not match the root-owned release pair or armed transaction: expected {}, found {observed}",
        record.daemon_sha256
    )))
}

fn verify_daemon_digest_at(record: &ReleasePairRecord, daemon_path: &Path) -> Result<(), CliError> {
    let daemon_path = validate_trusted_executable("daemon", daemon_path)?;
    let observed = sha256_file(&daemon_path)?;
    if observed == record.daemon_sha256 {
        Ok(())
    } else {
        Err(io_error(format!(
            "installed daemon digest does not match the root-owned release pair: expected {}, found {observed}",
            record.daemon_sha256
        )))
    }
}

impl ReleasePairRecord {
    fn validate_structure(&self) -> Result<(), CliError> {
        if self.record_version != RELEASE_PAIR_RECORD_VERSION {
            return Err(io_error(format!(
                "unsupported release pair record version {}",
                self.record_version
            )));
        }
        if self.lifecycle_protocol_version != LIFECYCLE_PROTOCOL_VERSION {
            return Err(io_error(format!(
                "unsupported systemd lifecycle protocol version {}",
                self.lifecycle_protocol_version
            )));
        }
        validate_canonical_unit_name(&self.canonical_unit)?;
        validate_record_path("daemon", &self.daemon_path)?;
        validate_record_path("controller", &self.controller_path)?;
        validate_digest("daemon", &self.daemon_sha256)?;
        validate_digest("controller", &self.controller_sha256)?;
        parse_release_version(&self.release_identity)?;
        Ok(())
    }

    fn validate_current(&self) -> Result<(), CliError> {
        self.validate_structure()?;
        if self.release_identity != release_identity() {
            return Err(io_error(format!(
                "release pair identity {} does not match controller {}",
                self.release_identity,
                release_identity()
            )));
        }
        Ok(())
    }

    fn validate_for(&self, plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
        self.validate_current()?;
        let daemon_path = canonical_path("daemon", &plan.binary_path)?;
        if self.canonical_unit == plan.unit && self.daemon_path == daemon_path {
            Ok(())
        } else {
            Err(io_error(format!(
                "release pair does not bind systemd unit {} and daemon {}",
                plan.unit,
                plan.binary_path.display()
            )))
        }
    }
}

fn write_record(store_path: &Path, record: &ReleasePairRecord) -> Result<(), CliError> {
    write_json_atomic(&record_path(store_path), record)
}

fn load_required_record(store_path: &Path) -> Result<ReleasePairRecord, CliError> {
    load_record(store_path)?.ok_or_else(|| {
        io_error(format!(
            "missing root-owned controller/daemon release pair at {}; run harness-systemd install before lifecycle mutation",
            record_path(store_path).display()
        ))
    })
}

fn load_record(store_path: &Path) -> Result<Option<ReleasePairRecord>, CliError> {
    let path = record_path(store_path);
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(io_error(format!(
                "inspect release pair record {}: {error}",
                path.display()
            )));
        }
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(io_error(format!(
            "release pair record is not a regular file: {}",
            path.display()
        )));
    }
    if metadata.uid() != trusted_uid() || metadata.mode() & 0o077 != 0 {
        return Err(io_error(format!(
            "release pair record must be trusted-owner and private: {}",
            path.display()
        )));
    }
    let bytes = fs::read(&path).map_err(|error| {
        io_error(format!(
            "read release pair record {}: {error}",
            path.display()
        ))
    })?;
    let record: ReleasePairRecord = serde_json::from_slice(&bytes).map_err(|error| {
        io_error(format!(
            "decode release pair record {}: {error}",
            path.display()
        ))
    })?;
    record.validate_structure()?;
    Ok(Some(record))
}

fn validate_idle_controller_rotation(
    existing: &ReleasePairRecord,
    requested: &ReleasePairRecord,
) -> Result<(), CliError> {
    existing.validate_structure()?;
    requested.validate_current()?;
    if existing.record_version != requested.record_version
        || existing.lifecycle_protocol_version != requested.lifecycle_protocol_version
        || existing.canonical_unit != requested.canonical_unit
        || existing.daemon_path != requested.daemon_path
        || existing.daemon_sha256 != requested.daemon_sha256
    {
        return Err(io_error(format!(
            "controller rotation for {} must preserve the canonical daemon binding",
            existing.canonical_unit
        )));
    }
    let existing_version = parse_release_version(&existing.release_identity)?;
    let requested_version = parse_release_version(&requested.release_identity)?;
    if requested_version <= existing_version {
        return Err(io_error(format!(
            "refusing stale or same-release systemd controller rotation from {} to {}",
            existing.release_identity, requested.release_identity
        )));
    }
    Ok(())
}

fn ensure_pair_rotation_idle(store_path: &Path) -> Result<(), CliError> {
    for (label, path) in [
        ("recovery arm", store_path.join(RECOVERY_ARM_FILE)),
        ("pending generation", store_path.join(PENDING_DIRECTORY)),
        (
            "interrupted generation rotation",
            store_path.join(PREVIOUS_OLD_DIRECTORY),
        ),
    ] {
        match fs::symlink_metadata(&path) {
            Ok(_) => {
                return Err(io_error(format!(
                    "refusing controller rotation while {label} exists at {}",
                    path.display()
                )));
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => {
                return Err(io_error(format!(
                    "inspect controller rotation state {}: {error}",
                    path.display()
                )));
            }
        }
    }
    Ok(())
}

fn validate_record_path(label: &str, path: &Path) -> Result<(), CliError> {
    if path.is_absolute() {
        Ok(())
    } else {
        Err(io_error(format!(
            "release pair {label} path is not absolute: {}",
            path.display()
        )))
    }
}

fn validate_digest(label: &str, digest: &str) -> Result<(), CliError> {
    if digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(io_error(format!(
            "release pair {label} digest is not SHA-256"
        )))
    }
}

fn parse_release_version(identity: &str) -> Result<Version, CliError> {
    let version = identity
        .strip_prefix("harness-systemd/")
        .ok_or_else(|| io_error(format!("invalid release pair identity {identity}")))?;
    Version::parse(version)
        .map_err(|error| io_error(format!("invalid release pair version {identity}: {error}")))
}

fn record_path(store_path: &Path) -> PathBuf {
    store_path.join(RELEASE_PAIR_FILE)
}

fn release_identity() -> String {
    format!("harness-systemd/{}", env!("CARGO_PKG_VERSION"))
}

fn recovery_controller_source(plan: &RemoteSystemdOperationPlan) -> PathBuf {
    plan.recovery_controller_path()
}

#[cfg(test)]
#[path = "release_pair/tests.rs"]
mod tests;
