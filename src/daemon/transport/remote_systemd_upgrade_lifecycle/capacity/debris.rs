use std::io::ErrorKind;
use std::path::Path;

use fs_err as fs;

use crate::errors::CliError;

use super::super::files::{
    io_error, reconcile_atomic_copy_debris, remove_tree_if_exists, sync_directory,
};
use super::super::model::RemoteSystemdOperationPlan;

pub(super) fn reconcile_restore_debris(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    for path in [&plan.binary_path, &plan.unit_path, &plan.environment_path] {
        reconcile_atomic_copy_debris(path)?;
    }
    let parent = plan
        .state_path
        .parent()
        .ok_or_else(|| io_error("systemd state path has no parent"))?;
    let entries = match fs::read_dir(parent) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(io_error(format!(
                "read systemd state parent {}: {error}",
                parent.display()
            )));
        }
    };
    let mut changed = false;
    for entry in entries {
        let entry = entry.map_err(|error| io_error(format!("read restore debris: {error}")))?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with(".harness-restore-") {
            remove_tree_if_exists(&entry.path())?;
            changed = true;
        } else if name.starts_with(".harness-displaced-") {
            reconcile_displaced(plan, &entry.path())?;
            changed = true;
        }
    }
    if changed {
        sync_directory(parent)?;
    }
    Ok(())
}

fn reconcile_displaced(
    plan: &RemoteSystemdOperationPlan,
    displaced: &Path,
) -> Result<(), CliError> {
    match fs::symlink_metadata(&plan.state_path) {
        Ok(_) => remove_untrusted_path(displaced),
        Err(error) if error.kind() == ErrorKind::NotFound => {
            fs::rename(displaced, &plan.state_path).map_err(|error| {
                io_error(format!(
                    "restore displaced systemd state {}: {error}",
                    plan.state_path.display()
                ))
            })
        }
        Err(error) => Err(io_error(format!(
            "inspect systemd state {}: {error}",
            plan.state_path.display()
        ))),
    }
}

fn remove_untrusted_path(path: &Path) -> Result<(), CliError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {
            fs::remove_dir_all(path).map_err(|error| {
                io_error(format!(
                    "remove restore debris directory {}: {error}",
                    path.display()
                ))
            })
        }
        Ok(_) => fs::remove_file(path).map_err(|error| {
            io_error(format!(
                "remove restore debris entry {}: {error}",
                path.display()
            ))
        }),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error(format!(
            "inspect restore debris {}: {error}",
            path.display()
        ))),
    }
}
