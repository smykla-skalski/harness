use super::{Arc, CliError, DaemonDb, Mutex, OnceLock, state};
use crate::daemon::db_handle::DaemonDbOwnedHandle;
use crate::daemon::db_open::DaemonDbOpen;

pub(crate) fn ensure_shared_db(
    db_slot: &Arc<OnceLock<Arc<Mutex<DaemonDbOwnedHandle>>>>,
) -> Result<Arc<Mutex<DaemonDbOwnedHandle>>, CliError> {
    if let Some(db) = db_slot.get() {
        return Ok(Arc::clone(db));
    }

    // Nothing guarantees the daemon root exists by the time a lazy caller lands
    // here - it is created by whichever audit, lock, or manifest write happens
    // to run first, and a caller that beats all three opens against a missing
    // directory.
    state::ensure_daemon_dirs()?;
    let db_path = state::daemon_root().join("harness.db");
    let db = Arc::new(Mutex::new(DaemonDbOwnedHandle(DaemonDb::open(&db_path)?)));
    let _ = db_slot.set(Arc::clone(&db));
    Ok(db_slot.get().cloned().unwrap_or(db))
}
