use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::Path;

use fs2::FileExt;

use crate::errors::{CliError, CliErrorKind};

/// Error-message context shared by flock-backed persistence helpers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FlockErrorContext {
    scope: &'static str,
}

impl FlockErrorContext {
    #[must_use]
    pub const fn new(scope: &'static str) -> Self {
        Self { scope }
    }

    fn dir_error(self, parent: &Path, error: &io::Error) -> CliError {
        CliErrorKind::workflow_io(format!(
            "{}: failed to create lock directory {}: {}",
            self.scope,
            parent.display(),
            error
        ))
        .into()
    }

    fn open_error(self, path: &Path, error: &io::Error) -> CliError {
        CliErrorKind::workflow_io(format!(
            "{}: failed to open lock {}: {}",
            self.scope,
            path.display(),
            error
        ))
        .into()
    }

    fn acquire_error(self, path: &Path, error: &io::Error) -> CliError {
        CliErrorKind::workflow_io(format!(
            "{}: failed to acquire lock {}: {}",
            self.scope,
            path.display(),
            error
        ))
        .into()
    }

    fn release_error(self, path: &Path, error: &io::Error) -> CliError {
        CliErrorKind::workflow_io(format!(
            "{}: failed to release lock {}: {}",
            self.scope,
            path.display(),
            error
        ))
        .into()
    }
}

/// An RAII guard that holds an exclusive `flock` for the current process.
#[must_use = "drop the guard to release the flock"]
#[derive(Debug)]
pub struct FlockGuard {
    file: File,
}

impl Drop for FlockGuard {
    fn drop(&mut self) {
        let _ = self.file.unlock();
    }
}

/// Non-blocking flock-acquire failure.
#[derive(Debug)]
pub enum TryAcquireFlockError {
    Busy,
    Io(CliError),
}

fn open_lock_file(path: &Path, context: FlockErrorContext) -> Result<File, CliError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| context.dir_error(parent, &error))?;
    }
    OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(path)
        .map_err(|error| context.open_error(path, &error))
}

/// Acquire an exclusive `flock`, blocking until it becomes available.
///
/// # Errors
/// Returns [`CliError`] when the lock file cannot be opened, acquired, or
/// released.
pub fn with_exclusive_flock<T>(
    path: &Path,
    context: FlockErrorContext,
    action: impl FnOnce() -> Result<T, CliError>,
) -> Result<T, CliError> {
    let file = open_lock_file(path, context)?;
    file.lock_exclusive()
        .map_err(|error| context.acquire_error(path, &error))?;
    let result = action();
    let unlock = file
        .unlock()
        .map_err(|error| context.release_error(path, &error));
    match (result, unlock) {
        (Ok(value), Ok(())) => Ok(value),
        (Err(error), Ok(()) | Err(_)) | (Ok(_), Err(error)) => Err(error),
    }
}

/// Attempt to acquire an exclusive `flock` without blocking.
///
/// # Errors
/// Returns [`TryAcquireFlockError::Busy`] when another process already holds
/// the lock, or [`TryAcquireFlockError::Io`] for filesystem failures.
pub fn try_acquire_exclusive_flock(
    path: &Path,
    context: FlockErrorContext,
) -> Result<FlockGuard, TryAcquireFlockError> {
    let file = open_lock_file(path, context).map_err(TryAcquireFlockError::Io)?;
    match file.try_lock_exclusive() {
        Ok(()) => Ok(FlockGuard { file }),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Err(TryAcquireFlockError::Busy),
        Err(error) => Err(TryAcquireFlockError::Io(
            context.acquire_error(path, &error),
        )),
    }
}

/// Probe whether the file at `path` is currently held by an exclusive `flock`.
#[must_use]
pub fn flock_is_held_at(path: &Path) -> bool {
    let Ok(file) = OpenOptions::new().read(true).write(true).open(path) else {
        return false;
    };
    match file.try_lock_exclusive() {
        Ok(()) => {
            let _ = file.unlock();
            false
        }
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => true,
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    use tempfile::tempdir;

    #[test]
    fn flock_is_held_at_returns_false_for_missing_file() {
        let tmp = tempdir().expect("tempdir");
        assert!(!flock_is_held_at(&tmp.path().join("missing.lock")));
    }

    #[test]
    fn flock_is_held_at_returns_false_for_unlocked_file() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("unlocked.lock");
        std::fs::write(&path, "").expect("create");
        assert!(!flock_is_held_at(&path));
    }

    #[test]
    fn flock_is_held_at_returns_true_while_another_holder_is_alive() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("held.lock");
        let _guard =
            try_acquire_exclusive_flock(&path, FlockErrorContext::new("test")).expect("acquire");
        assert!(flock_is_held_at(&path));
    }

    #[test]
    fn with_exclusive_flock_creates_missing_parent_directories() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("nested").join("dir").join("state.lock");
        with_exclusive_flock(&path, FlockErrorContext::new("test"), || Ok(()))
            .expect("lock should succeed");
        assert!(path.exists());
    }

    #[test]
    fn try_acquire_exclusive_flock_reports_busy_when_already_held() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("busy.lock");
        let _guard = try_acquire_exclusive_flock(&path, FlockErrorContext::new("test"))
            .expect("first acquire");
        let error = try_acquire_exclusive_flock(&path, FlockErrorContext::new("test"))
            .expect_err("second acquire should fail");
        assert!(matches!(error, TryAcquireFlockError::Busy));
    }

    #[test]
    fn flock_guard_releases_on_drop() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("release.lock");
        let guard = try_acquire_exclusive_flock(&path, FlockErrorContext::new("test"))
            .expect("first acquire");
        drop(guard);
        let _guard = try_acquire_exclusive_flock(&path, FlockErrorContext::new("test"))
            .expect("second acquire");
    }

    #[test]
    fn with_exclusive_flock_serializes_blocking_callers() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("serial.lock");
        let (first_enter_tx, first_enter_rx) = mpsc::channel();
        let (release_first_tx, release_first_rx) = mpsc::channel();
        let (second_enter_tx, second_enter_rx) = mpsc::channel();

        thread::scope(|scope| {
            let first_path = path.clone();
            scope.spawn(move || {
                with_exclusive_flock(&first_path, FlockErrorContext::new("test"), || {
                    first_enter_tx.send(()).expect("signal first enter");
                    release_first_rx.recv().expect("wait for release");
                    Ok(())
                })
                .expect("first lock");
            });

            first_enter_rx.recv().expect("first entered");

            let second_path = path.clone();
            scope.spawn(move || {
                with_exclusive_flock(&second_path, FlockErrorContext::new("test"), || {
                    second_enter_tx.send(()).expect("signal second enter");
                    Ok(())
                })
                .expect("second lock");
            });

            assert!(
                second_enter_rx
                    .recv_timeout(Duration::from_millis(150))
                    .is_err(),
                "second caller should block until the first releases the lock"
            );
            release_first_tx.send(()).expect("release first");
            second_enter_rx
                .recv_timeout(Duration::from_secs(2))
                .expect("second caller should acquire after release");
        });
    }

    #[test]
    fn with_exclusive_flock_returns_action_error() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("action-error.lock");
        let error = with_exclusive_flock(&path, FlockErrorContext::new("test"), || {
            Err::<(), CliError>(CliErrorKind::workflow_io("action failed").into())
        })
        .expect_err("action error should surface");
        assert!(error.to_string().contains("action failed"));
    }
}
