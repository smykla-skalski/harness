use std::fs::{File, Metadata};
use std::io::{ErrorKind, Read as _};
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use fs_err as fs;

use crate::errors::CliError;

use super::super::files::{
    io_error, open_regular_nofollow, validate_private_directory, write_json_atomic,
};
use super::super::model::{LEGACY_RECOVERY_ARM_VERSION, RECOVERY_ARM_VERSION};
use super::super::model::{RECOVERY_ARM_FILE, RecoveryArm, RemoteSystemdOperationPlan};

pub(super) fn load_recovery_arm(store_path: &Path) -> Result<Option<RecoveryArm>, CliError> {
    validate_private_directory(store_path)?;
    let path = store_path.join(RECOVERY_ARM_FILE);
    let Some(mut file) = open_recovery_arm(&path)? else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).map_err(|error| {
        io_error(format!(
            "read systemd recovery arm {}: {error}",
            path.display()
        ))
    })?;
    let arm = serde_json::from_slice::<RecoveryArm>(&bytes).map_err(|error| {
        io_error(format!(
            "decode systemd recovery arm {}: {error}",
            path.display()
        ))
    })?;
    arm.validate()?;
    Ok(Some(arm))
}

pub(super) fn write_recovery_arm(
    plan: &RemoteSystemdOperationPlan,
    arm: &RecoveryArm,
) -> Result<(), CliError> {
    arm.validate()?;
    if arm.arm_version == LEGACY_RECOVERY_ARM_VERSION {
        let existing = load_recovery_arm(&plan.store_path)?
            .ok_or_else(|| io_error("refusing to create a new legacy systemd recovery arm v2"))?;
        if existing.arm_version != LEGACY_RECOVERY_ARM_VERSION
            || existing.transaction_id != arm.transaction_id
        {
            return Err(io_error(
                "legacy systemd recovery arm update does not match the armed transaction",
            ));
        }
    } else if arm.arm_version != RECOVERY_ARM_VERSION {
        return Err(io_error(format!(
            "refusing to write unsupported systemd recovery arm version {}",
            arm.arm_version
        )));
    }
    write_json_atomic(&plan.recovery_arm_path(), arm)
}

fn open_recovery_arm(path: &Path) -> Result<Option<File>, CliError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err(io_error(format!(
                "systemd recovery arm is not a regular file: {}",
                path.display()
            )))
        }
        Ok(_) => {
            let file = open_regular_nofollow(path)?;
            validate_recovery_arm_metadata(
                path,
                &file.metadata().map_err(|error| {
                    io_error(format!(
                        "inspect open systemd recovery arm {}: {error}",
                        path.display()
                    ))
                })?,
            )?;
            Ok(Some(file))
        }
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io_error(format!(
            "inspect systemd recovery arm {}: {error}",
            path.display()
        ))),
    }
}

fn validate_recovery_arm_metadata(path: &Path, metadata: &Metadata) -> Result<(), CliError> {
    if metadata.uid() != trusted_uid() || metadata.mode() & 0o022 != 0 {
        Err(io_error(format!(
            "systemd recovery arm must be trusted-owner and not group or world writable: {}",
            path.display()
        )))
    } else {
        Ok(())
    }
}

#[cfg(not(test))]
const fn trusted_uid() -> u32 {
    0
}

#[cfg(test)]
fn trusted_uid() -> u32 {
    uzers::get_current_uid()
}

#[cfg(test)]
mod tests {
    use std::fs::Permissions;
    use std::os::unix::fs::PermissionsExt as _;

    use tempfile::tempdir;

    use super::super::super::files::create_private_directory;
    use super::super::super::model::RECOVERY_ARM_VERSION;
    use super::*;

    #[test]
    fn recovery_load_rejects_insecure_store_ancestry() {
        let temp = tempdir().expect("temporary directory");
        let writable = temp.path().join("writable");
        fs::create_dir(&writable).expect("writable ancestor");
        fs::set_permissions(&writable, Permissions::from_mode(0o770))
            .expect("writable permissions");
        let store = writable.join("store");
        fs::create_dir(&store).expect("store");

        let error = load_recovery_arm(&store).expect_err("untrusted ancestry must fail");

        assert!(error.to_string().contains("group or world writable"));
    }

    #[test]
    fn recovery_load_rejects_writable_arm_file() {
        let temp = tempdir().expect("temporary directory");
        let store = temp.path().join("store");
        create_private_directory(&store).expect("private store");
        let arm = store.join(RECOVERY_ARM_FILE);
        fs::write(&arm, b"{}\n").expect("arm file");
        fs::set_permissions(&arm, Permissions::from_mode(0o660)).expect("writable arm permissions");

        let error = load_recovery_arm(&store).expect_err("writable arm must fail");

        assert!(
            error
                .to_string()
                .contains("recovery arm must be trusted-owner")
        );
    }

    #[test]
    fn recovery_load_rejects_unsealed_committing_arm() {
        let temp = tempdir().expect("temporary directory");
        let store = temp.path().join("store");
        create_private_directory(&store).expect("private store");
        let arm = serde_json::json!({
            "arm_version": RECOVERY_ARM_VERSION,
            "transaction_id": "test-transaction",
            "operation": "upgrade",
            "phase": "committing",
            "unit": "harness-remote",
            "binary_path": "/usr/local/bin/harness-daemon",
            "unit_path": "/etc/systemd/system/harness-remote.service",
            "environment_path": "/etc/harness/harness-remote.env",
            "state_path": "/var/lib/harness-remote",
            "store_path": store.display().to_string(),
            "readiness_timeout_seconds": 60,
            "stabilization_window_seconds": 5,
            "original_enabled": true,
            "before_sha256": "before",
            "target_sha256": "target",
            "controller_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        });
        fs::write(
            store.join(RECOVERY_ARM_FILE),
            serde_json::to_vec(&arm).expect("encode arm"),
        )
        .expect("write arm");

        let error = load_recovery_arm(&store).expect_err("unsealed committing arm must fail");

        assert!(error.to_string().contains("no target database seal"));
    }

    #[test]
    fn recovery_load_accepts_already_armed_legacy_v2_without_controller_digest() {
        let temp = tempdir().expect("temporary directory");
        let store = temp.path().join("store");
        create_private_directory(&store).expect("private store");
        let arm = serde_json::json!({
            "arm_version": super::super::super::model::LEGACY_RECOVERY_ARM_VERSION,
            "transaction_id": "legacy-transaction",
            "operation": "upgrade",
            "phase": "armed",
            "unit": "harness-remote",
            "binary_path": "/usr/local/bin/harness-daemon",
            "unit_path": "/etc/systemd/system/harness-remote.service",
            "environment_path": "/etc/harness/harness-remote.env",
            "state_path": "/var/lib/harness-remote",
            "store_path": store.display().to_string(),
            "readiness_timeout_seconds": 60,
            "stabilization_window_seconds": 5,
            "original_enabled": true,
            "before_sha256": "before",
            "target_sha256": "target"
        });
        let legacy: RecoveryArm =
            serde_json::from_value(arm.clone()).expect("decode legacy recovery arm");
        let plan = legacy.plan().expect("legacy recovery plan");
        let error = write_recovery_arm(&plan, &legacy)
            .expect_err("new commands must not create a legacy recovery arm");
        assert!(error.to_string().contains("refusing to create"));
        fs::write(
            store.join(RECOVERY_ARM_FILE),
            serde_json::to_vec(&arm).expect("encode legacy arm"),
        )
        .expect("write legacy arm");

        let loaded = load_recovery_arm(&store)
            .expect("load legacy arm")
            .expect("legacy arm");

        assert_eq!(
            loaded.arm_version,
            super::super::super::model::LEGACY_RECOVERY_ARM_VERSION
        );
        assert!(loaded.controller_sha256.is_none());
        write_recovery_arm(&plan, &loaded).expect("rewrite existing legacy arm");
    }
}
