use std::env;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Command;

#[cfg(unix)]
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

use super::{
    WORKER_DIR_ENV, WorkerError, exec, resolve_sibling_worker, validate_override,
    validate_worker_name,
};

/// Replace the current process with a trusted sibling worker.
///
/// Unlike ordinary worker delegation, this validates executable ownership,
/// permissions, and ancestors before probing or executing a development override.
///
/// # Errors
/// Returns an error when resolution, trust validation, version probing, or
/// process replacement fails.
pub fn exec_trusted_worker<I, S>(
    name: &str,
    expected_version: &str,
    args: I,
) -> Result<i32, WorkerError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let worker = resolve_trusted_worker(name, expected_version)?;
    let mut command = Command::new(&worker);
    command.args(args);
    exec(&mut command, &worker)
}

/// Resolve a trusted sibling worker without executing it.
///
/// Development overrides are ownership- and permission-validated before their
/// version probe runs.
///
/// # Errors
/// Returns an error when resolution, trust validation, or version probing fails.
pub fn resolve_trusted_worker(name: &str, expected_version: &str) -> Result<PathBuf, WorkerError> {
    validate_worker_name(name)?;
    if let Some(directory) = env::var_os(WORKER_DIR_ENV).filter(|value| !value.is_empty()) {
        return resolve_trusted_override(&PathBuf::from(directory), name, expected_version);
    }
    let executable = env::current_exe()
        .map_err(|error| WorkerError::new(format!("resolve current executable: {error}")))?;
    let worker = resolve_sibling_worker(&executable, name)?;
    trusted_worker_path(&worker, name)
}

fn resolve_trusted_override(
    directory: &Path,
    name: &str,
    expected_version: &str,
) -> Result<PathBuf, WorkerError> {
    let worker = trusted_worker_path(&directory.join(name), name)?;
    validate_override(&worker, name, expected_version)?;
    Ok(worker)
}

fn trusted_worker_path(path: &Path, name: &str) -> Result<PathBuf, WorkerError> {
    let path = path.canonicalize().map_err(|error| {
        WorkerError::new(format!(
            "resolve trusted Harness worker {name} at {}: {error}",
            path.display()
        ))
    })?;
    validate_trusted_file(&path, name)?;
    validate_trusted_ancestors(&path, name)?;
    Ok(path)
}

#[cfg(unix)]
fn validate_trusted_file(path: &Path, name: &str) -> Result<(), WorkerError> {
    let metadata = path.symlink_metadata().map_err(|error| {
        WorkerError::new(format!(
            "inspect trusted Harness worker {name} at {}: {error}",
            path.display()
        ))
    })?;
    let trusted_uid = uzers::get_effective_uid();
    if !metadata.is_file()
        || metadata.uid() != trusted_uid
        || metadata.permissions().mode() & 0o022 != 0
        || metadata.permissions().mode() & 0o111 == 0
    {
        return Err(WorkerError::new(format!(
            "trusted Harness worker {name} must be an executable owned by uid {trusted_uid} and not group or world writable: {}",
            path.display()
        )));
    }
    Ok(())
}

#[cfg(not(unix))]
fn validate_trusted_file(path: &Path, name: &str) -> Result<(), WorkerError> {
    if path.is_file() {
        Ok(())
    } else {
        Err(WorkerError::new(format!(
            "trusted Harness worker {name} is not a file: {}",
            path.display()
        )))
    }
}

#[cfg(unix)]
fn validate_trusted_ancestors(path: &Path, name: &str) -> Result<(), WorkerError> {
    let trusted_uid = uzers::get_effective_uid();
    for ancestor in path.parent().into_iter().flat_map(Path::ancestors) {
        let metadata = ancestor.symlink_metadata().map_err(|error| {
            WorkerError::new(format!(
                "inspect trusted Harness worker {name} ancestor {}: {error}",
                ancestor.display()
            ))
        })?;
        let trusted_owner = metadata.uid() == trusted_uid || metadata.uid() == 0;
        let sticky_root = metadata.uid() == 0 && metadata.mode() & 0o1000 != 0;
        if !metadata.is_dir() || !trusted_owner || metadata.mode() & 0o022 != 0 && !sticky_root {
            return Err(WorkerError::new(format!(
                "trusted Harness worker {name} has an untrusted ancestor: {}",
                ancestor.display()
            )));
        }
    }
    Ok(())
}

#[cfg(not(unix))]
fn validate_trusted_ancestors(_path: &Path, _name: &str) -> Result<(), WorkerError> {
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt as _;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn trusted_worker_rejects_writable_executable() {
        let temporary = tempdir().expect("temporary directory");
        let worker = temporary.path().join("harness-systemd");
        fs::write(&worker, "#!/bin/sh\n").expect("worker");
        fs::set_permissions(&worker, fs::Permissions::from_mode(0o777)).expect("writable worker");

        let error =
            trusted_worker_path(&worker, "harness-systemd").expect_err("writable worker rejected");

        assert!(error.to_string().contains("not group or world writable"));
    }

    #[test]
    fn trusted_override_is_validated_before_version_probe() {
        let temporary = tempdir().expect("temporary directory");
        let marker = temporary.path().join("probe-ran");
        let worker = temporary.path().join("harness-systemd");
        fs::write(
            &worker,
            format!("#!/bin/sh\ntouch '{}'\n", marker.display()),
        )
        .expect("worker");
        fs::set_permissions(&worker, fs::Permissions::from_mode(0o777)).expect("writable worker");

        resolve_trusted_override(
            temporary.path(),
            "harness-systemd",
            env!("CARGO_PKG_VERSION"),
        )
        .expect_err("writable override rejected before probe");

        assert!(!marker.exists());
    }

    #[test]
    fn trusted_worker_rejects_writable_ancestor() {
        let temporary = tempdir().expect("temporary directory");
        let writable = temporary.path().join("writable");
        fs::create_dir(&writable).expect("writable directory");
        fs::set_permissions(&writable, fs::Permissions::from_mode(0o777))
            .expect("writable permissions");
        let worker = writable.join("harness-systemd");
        fs::write(&worker, "#!/bin/sh\n").expect("worker");
        fs::set_permissions(&worker, fs::Permissions::from_mode(0o755))
            .expect("worker permissions");

        let error = trusted_worker_path(&worker, "harness-systemd").expect_err("ancestor rejected");

        assert!(error.to_string().contains("untrusted ancestor"));
    }
}
