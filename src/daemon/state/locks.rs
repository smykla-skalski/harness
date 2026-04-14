use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::persistence::flock::{
    FlockErrorContext, TryAcquireFlockError, flock_is_held_at as shared_flock_is_held_at,
    try_acquire_exclusive_flock,
};

use super::{DaemonLockGuard, FlockGuard, ensure_daemon_dirs, load_manifest, lock_path};

pub(crate) fn acquire_flock_exclusive(
    path: &Path,
    label: &'static str,
) -> Result<FlockGuard, CliError> {
    match try_acquire_exclusive_flock(path, FlockErrorContext::new(label)) {
        Ok(guard) => Ok(guard),
        Err(TryAcquireFlockError::Busy) => {
            Err(CliErrorKind::workflow_io(format!("{label} already running")).into())
        }
        Err(TryAcquireFlockError::Io(error)) => Err(error),
    }
}

#[must_use]
pub(crate) fn flock_is_held_at(path: &Path) -> bool {
    shared_flock_is_held_at(path)
}

pub fn acquire_singleton_lock() -> Result<DaemonLockGuard, CliError> {
    ensure_daemon_dirs()?;
    acquire_flock_exclusive(&lock_path(), "daemon").map_err(|_| {
        let detail = load_manifest().ok().flatten().map_or_else(
            || "daemon already running".to_string(),
            |manifest| {
                format!(
                    "daemon already running (pid {}, endpoint {})",
                    manifest.pid, manifest.endpoint
                )
            },
        );
        CliErrorKind::workflow_io(detail).into()
    })
}

#[must_use]
pub fn daemon_lock_is_held() -> bool {
    daemon_lock_is_held_at(&lock_path())
}

#[inline]
#[must_use]
pub fn daemon_lock_is_held_at(lock_path: &Path) -> bool {
    flock_is_held_at(lock_path)
}
