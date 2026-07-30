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
    // Walk root-to-leaf (`Path::ancestors` yields the opposite order) so a
    // sticky root like `/tmp` is seen before the trusted user's own
    // directories beneath it, which the group-write exception below depends
    // on having already observed.
    let ancestors: Vec<&Path> = path
        .parent()
        .into_iter()
        .flat_map(Path::ancestors)
        .collect();
    let mut under_sticky_root = false;
    for ancestor in ancestors.into_iter().rev() {
        let metadata = ancestor.symlink_metadata().map_err(|error| {
            WorkerError::new(format!(
                "inspect trusted Harness worker {name} ancestor {}: {error}",
                ancestor.display()
            ))
        })?;
        let trusted_owner = metadata.uid() == trusted_uid || metadata.uid() == 0;
        let is_sticky_root = metadata.uid() == 0 && metadata.mode() & 0o1000 != 0;
        under_sticky_root |= is_sticky_root;
        // World-write always disqualifies an ancestor unless it is itself the
        // sticky root (matching `/tmp`'s own 1777 mode: its sticky bit already
        // stops anyone but a file's owner from renaming or deleting it).
        //
        // Group-write is weaker, and only forgiven once under a sticky root
        // and only for a directory the trusted user themselves owns: an
        // ambient `umask 002` is enough to leave a plain `tempfile::tempdir()`
        // group-writable (issue #1239), and rejecting that made every
        // worker-override test under a permissive umask fail before reaching
        // the fake worker it stood up. This is a deliberate, narrower trust
        // boundary, not a fully closed one: `/tmp`'s sticky bit stops another
        // user from renaming or deleting the trusted-owned directory *entry*
        // within `/tmp`, but a directory that is itself merely group-writable
        // (not sticky itself) still lets any member of its owning group
        // replace entries *inside* it - including the worker binary - between
        // this check and the later `Command::new(&worker)` exec. Closing that
        // gap needs opening the worker by fd and exec'ing the already-open,
        // already-validated fd instead of a path (tracked in #1242); until
        // then, this exception intentionally treats members of the trusted
        // user's own group as trusted for directories the trusted user
        // themselves created under a sticky root, matching the issue's own
        // framing of "not writable by anyone outside the trusted user's own
        // group-write policy". Outside a sticky root, group-write on a
        // trusted-owned ancestor still disqualifies it unconditionally.
        let disqualifying_mode = if is_sticky_root {
            false
        } else {
            metadata.mode() & 0o002 != 0
                || (metadata.mode() & 0o020 != 0
                    && !(under_sticky_root && metadata.uid() == trusted_uid))
        };
        if !metadata.is_dir() || !trusted_owner || disqualifying_mode {
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

    use rustix::fs::Mode;
    use tempfile::tempdir;

    use super::*;

    /// Restores the process umask on drop, including on test panic; `umask`
    /// is process-wide state, and nextest gives each test its own process,
    /// but restoring promptly still keeps a single test from leaking mode
    /// bits into anything else that process goes on to do.
    struct RestoreUmask(Mode);

    impl Drop for RestoreUmask {
        fn drop(&mut self) {
            rustix::process::umask(self.0);
        }
    }

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

    #[test]
    fn trusted_worker_allows_own_tempdir_under_permissive_umask() {
        // Issue #1239: `umask 002` leaves the group-write bit set on a plain
        // `tempfile::tempdir()`, which sits under `/tmp`'s sticky root and is
        // owned by this process - not writable by anyone the sticky bit
        // doesn't already stop. Built explicitly under `/tmp` (bypassing
        // `TMPDIR`) so the sticky-root ancestor this test relies on is
        // guaranteed rather than however the host's temp directory happens
        // to be configured.
        let root_metadata = fs::symlink_metadata("/tmp").expect("/tmp metadata");
        assert_eq!(root_metadata.uid(), 0, "expected /tmp to be root-owned");
        assert_ne!(
            root_metadata.mode() & 0o1000,
            0,
            "expected /tmp to carry the sticky bit"
        );

        let previous = rustix::process::umask(Mode::from_raw_mode(0o002));
        let _restore = RestoreUmask(previous);

        let temporary = tempfile::Builder::new()
            .tempdir_in("/tmp")
            .expect("temporary directory under /tmp");
        let ancestor_mode = fs::symlink_metadata(temporary.path())
            .expect("tempdir metadata")
            .permissions()
            .mode();
        assert_eq!(
            ancestor_mode & 0o022,
            0o020,
            "expected umask 002 to leave the tempdir group-writable but not world-writable, got {ancestor_mode:o}"
        );

        let worker = temporary.path().join("harness-systemd");
        fs::write(&worker, "#!/bin/sh\n").expect("worker");
        fs::set_permissions(&worker, fs::Permissions::from_mode(0o755))
            .expect("worker permissions");

        trusted_worker_path(&worker, "harness-systemd")
            .expect("own tempdir under a sticky root is trusted regardless of ambient umask");
    }
}
