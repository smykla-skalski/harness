use std::env;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Command;

#[cfg(unix)]
use std::fs::File;
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
#[cfg(unix)]
use std::os::unix::io::AsRawFd as _;

use super::{
    WORKER_DIR_ENV, WorkerError, exec, resolve_sibling_worker, validate_override,
    validate_worker_name,
};

/// Replace the current process with a trusted sibling worker.
///
/// Unlike ordinary worker delegation, this validates executable ownership,
/// permissions, and ancestors before probing or executing a development
/// override, and execs the exact file descriptor it validated instead of
/// reopening the worker's path: a file swapped in after validation can't
/// change what actually runs.
///
/// # Errors
/// Returns an error when resolution, trust validation, version probing, or
/// process replacement fails.
#[cfg(unix)]
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
    let file = open_validated_trusted_file(&worker, name)?;
    let mut command = Command::new(format!("/dev/fd/{}", file.as_raw_fd()));
    command.args(args);
    exec(&mut command, &worker)
}

/// Replace the current process with a trusted sibling worker.
///
/// # Errors
/// Returns an error when resolution, trust validation, version probing, or
/// process replacement fails.
#[cfg(not(unix))]
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
    check_trusted_metadata(&metadata, name, path)
}

/// Shared by the path-based check above (used while resolving a worker,
/// including for purposes - like writing a systemd unit file - that need a
/// stable path rather than an open file) and the fd-based check in
/// [`open_validated_trusted_file`] below (used right before exec, where an
/// open descriptor's `fstat` result can't be swapped out from under it).
#[cfg(unix)]
fn check_trusted_metadata(
    metadata: &std::fs::Metadata,
    name: &str,
    path: &Path,
) -> Result<(), WorkerError> {
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

/// Opens the already-resolved, already-validated worker path and re-checks
/// ownership and permissions through the open descriptor's own `fstat`
/// result, rather than trusting the earlier path-based check to still hold.
/// The returned file is the exec target `exec_trusted_worker` uses via
/// `/dev/fd/{fd}`, so whatever this validated is exactly what runs, even if
/// the file at `path` is replaced immediately afterward.
///
/// # Errors
/// Returns an error when the file can't be opened, inspected, or marked to
/// survive exec, or when its owner or permissions don't pass validation.
#[cfg(unix)]
fn open_validated_trusted_file(path: &Path, name: &str) -> Result<File, WorkerError> {
    let file = File::from(
        rustix::fs::open(
            path,
            rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .map_err(|error| {
            WorkerError::new(format!(
                "open trusted Harness worker {name} at {}: {error}",
                path.display()
            ))
        })?,
    );
    let metadata = file.metadata().map_err(|error| {
        WorkerError::new(format!(
            "inspect trusted Harness worker {name} at {}: {error}",
            path.display()
        ))
    })?;
    check_trusted_metadata(&metadata, name, path)?;
    // A shebang'd worker's interpreter reopens `/dev/fd/{fd}` itself once the
    // kernel hands it control, which only resolves if this descriptor is
    // still open in the exec'd image; a plain executable doesn't need it,
    // but leaving it open for one is harmless.
    rustix::io::fcntl_setfd(&file, rustix::io::FdFlags::empty()).map_err(|error| {
        WorkerError::new(format!(
            "clear close-on-exec for trusted Harness worker {name} at {}: {error}",
            path.display()
        ))
    })?;
    Ok(file)
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
        // Group-write is weaker, and only forgiven once under a sticky root,
        // for every ancestor from there down that the trusted user themselves
        // own: an ambient `umask 002` is enough to leave a plain
        // `tempfile::tempdir()` group-writable (issue #1239), and rejecting
        // that made every worker-override test under a permissive umask fail
        // before reaching the fake worker it stood up. This has to reach more
        // than the sticky root's immediate children: `TMPDIR` and equivalent
        // sandboxing routinely nest a process- or lane-scoped scratch
        // directory (still trusted-user-owned, still under the same umask)
        // between the sticky root and the actual leaf tempdir, exactly as
        // this repository's own test lane does; restricting the exception to
        // one hop reopens the original bug there. `trusted_owner` above is
        // still checked unconditionally on every ancestor in the chain, so
        // the exception never crosses into a directory some other identity
        // owns - only the trusted user's own group-write policy is being
        // forgiven, matching the issue's own framing of "not writable by
        // anyone outside the trusted user's own group-write policy". This is
        // a deliberate, narrower trust boundary, not a fully closed one: even
        // a direct child lets a member of its owning group replace entries
        // *inside* it - including the worker binary - between this check and
        // the later `Command::new(&worker)` exec. Closing that gap needs
        // opening the worker by fd and exec'ing the already-open,
        // already-validated fd instead of a path (tracked in #1242).
        // Outside a sticky root, group-write on a trusted-owned ancestor
        // still disqualifies it unconditionally.
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
    use std::io::Read as _;
    use std::os::unix::fs::PermissionsExt as _;

    use std::sync::{Mutex, MutexGuard};

    use rustix::fs::Mode;
    use tempfile::tempdir;

    use super::*;

    /// Serializes umask mutation across tests in this module. `umask` is
    /// process-wide state: nextest (this repo's canonical gate) runs each
    /// test in its own process and never needs this, but `cargo test`'s
    /// shared, multi-threaded process could let two umask-mutating tests
    /// race and leak mode bits into each other without it.
    static UMASK_LOCK: Mutex<()> = Mutex::new(());

    /// Holds `UMASK_LOCK` and restores the process umask on drop, including
    /// on test panic. A custom `Drop` impl's body always runs before its
    /// struct's fields drop, so the umask is restored, by the impl below,
    /// before `_guard` releases the lock - never the other way around.
    struct RestoreUmask<'a> {
        previous: Mode,
        _guard: MutexGuard<'a, ()>,
    }

    impl RestoreUmask<'_> {
        fn set(new_mask: Mode) -> Self {
            let guard = UMASK_LOCK
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let previous = rustix::process::umask(new_mask);
            Self {
                previous,
                _guard: guard,
            }
        }
    }

    impl Drop for RestoreUmask<'_> {
        fn drop(&mut self) {
            rustix::process::umask(self.previous);
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
        // Follows symlinks (`/tmp` is a symlink to `/private/tmp` on macOS):
        // the canonicalized worker path this test exercises resolves through
        // it the same way, so the precondition must check the real target.
        let root_metadata = fs::metadata("/tmp").expect("/tmp metadata");
        assert_eq!(root_metadata.uid(), 0, "expected /tmp to be root-owned");
        assert_ne!(
            root_metadata.mode() & 0o1000,
            0,
            "expected /tmp to carry the sticky bit"
        );

        let _restore = RestoreUmask::set(Mode::from_raw_mode(0o002));

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

    #[test]
    fn trusted_worker_allows_nested_group_writable_directories_under_sticky_root() {
        // Sandboxed test lanes (this repository's own included) commonly nest
        // a process-scoped scratch directory between the sticky root and the
        // actual leaf tempdir, all trusted-user-owned under the same ambient
        // umask. The group-write exception has to reach every such ancestor,
        // not just a sticky root's immediate child, or this exact shape of
        // worker-override path fails again under a permissive umask.
        let _restore = RestoreUmask::set(Mode::from_raw_mode(0o002));

        let temporary = tempfile::Builder::new()
            .tempdir_in("/tmp")
            .expect("temporary directory under /tmp");
        let nested = temporary.path().join("nested");
        fs::create_dir(&nested).expect("nested directory");
        let nested_mode = fs::symlink_metadata(&nested)
            .expect("nested directory metadata")
            .permissions()
            .mode();
        assert_eq!(
            nested_mode & 0o022,
            0o020,
            "expected umask 002 to leave the nested directory group-writable but not world-writable, got {nested_mode:o}"
        );

        let worker = nested.join("harness-systemd");
        fs::write(&worker, "#!/bin/sh\n").expect("worker");
        fs::set_permissions(&worker, fs::Permissions::from_mode(0o755))
            .expect("worker permissions");

        trusted_worker_path(&worker, "harness-systemd")
            .expect("nested trusted-owned directories under a sticky root are still trusted");
    }

    #[test]
    fn trusted_worker_rejects_world_writable_ancestor_at_any_depth_under_sticky_root() {
        // The group-write exception never covers world-write, no matter how
        // deep under a sticky root the ancestor sits: unlike group
        // membership, world-write means literally anyone could have swapped
        // this ancestor's contents, which is exactly the case the sticky
        // root's own protection was never meant to excuse.
        let temporary = tempfile::Builder::new()
            .tempdir_in("/tmp")
            .expect("temporary directory under /tmp");
        let nested = temporary.path().join("nested");
        fs::create_dir(&nested).expect("nested directory");
        let writable = nested.join("writable");
        fs::create_dir(&writable).expect("writable directory");
        fs::set_permissions(&writable, fs::Permissions::from_mode(0o777))
            .expect("writable permissions");
        let worker = writable.join("harness-systemd");
        fs::write(&worker, "#!/bin/sh\n").expect("worker");
        fs::set_permissions(&worker, fs::Permissions::from_mode(0o755))
            .expect("worker permissions");

        let error = trusted_worker_path(&worker, "harness-systemd")
            .expect_err("world-writable ancestor rejected regardless of sticky-root depth");
        assert!(error.to_string().contains("untrusted ancestor"));
    }

    /// Replaces whatever inode `path` names with a brand new one holding
    /// `contents`, the way an attacker's `rename` or `unlink`-then-`create`
    /// would: an in-place `fs::write` instead truncates the *same* inode,
    /// which every existing open descriptor (validated or not) would also
    /// see, so it can't stand in for "the file got swapped out" here.
    fn replace_file_at_path(path: &Path, contents: &str) {
        fs::remove_file(path).expect("remove original before replacing");
        fs::write(path, contents).expect("create replacement at the same path");
    }

    #[test]
    fn validated_worker_descriptor_is_immune_to_a_later_path_swap() {
        // The whole point of validating through an open descriptor: once
        // `open_validated_trusted_file` returns, nothing that happens to the
        // path afterward - including an attacker replacing the file the
        // instant after validation - can change what that descriptor reads.
        let temporary = tempdir().expect("temporary directory");
        let worker = temporary.path().join("harness-systemd");
        fs::write(&worker, "original").expect("write worker");
        fs::set_permissions(&worker, fs::Permissions::from_mode(0o755))
            .expect("worker permissions");

        let mut file =
            open_validated_trusted_file(&worker, "harness-systemd").expect("open validated worker");

        replace_file_at_path(&worker, "swapped");

        let mut contents = String::new();
        file.read_to_string(&mut contents)
            .expect("read from the already-open descriptor");
        assert_eq!(contents, "original");

        // Confirm the swap really happened at the path level, so the
        // assertion above is about the descriptor, not an accident.
        assert_eq!(
            fs::read_to_string(&worker).expect("read swapped path"),
            "swapped"
        );
    }

    #[test]
    fn dev_fd_exec_target_survives_a_later_path_swap() {
        // `exec_trusted_worker` execs `/dev/fd/{fd}`, not the worker's path.
        // This proves that mechanism itself - not just the descriptor
        // object - resolves to the validated content even after the file at
        // the original path is replaced, exactly what the kernel does
        // internally when `Command::new` execs that target.
        let temporary = tempdir().expect("temporary directory");
        let worker = temporary.path().join("harness-systemd");
        fs::write(&worker, "original").expect("write worker");
        fs::set_permissions(&worker, fs::Permissions::from_mode(0o755))
            .expect("worker permissions");

        let file =
            open_validated_trusted_file(&worker, "harness-systemd").expect("open validated worker");
        let dev_fd_path = format!("/dev/fd/{}", file.as_raw_fd());

        replace_file_at_path(&worker, "swapped");

        let contents = fs::read_to_string(&dev_fd_path).expect("read via /dev/fd exec target");
        assert_eq!(contents, "original");
    }

    #[test]
    fn validated_worker_refuses_to_follow_a_symlink() {
        let temporary = tempdir().expect("temporary directory");
        let real = temporary.path().join("harness-systemd");
        fs::write(&real, "original").expect("write real worker");
        fs::set_permissions(&real, fs::Permissions::from_mode(0o755))
            .expect("real worker permissions");

        let link = temporary.path().join("link-to-worker");
        std::os::unix::fs::symlink(&real, &link).expect("create symlink");

        let error = open_validated_trusted_file(&link, "harness-systemd")
            .expect_err("symlink rejected at open time");

        let message = error.to_string();
        assert!(
            message.contains("open trusted Harness worker harness-systemd"),
            "expected an open error, got: {message}"
        );
    }
}
