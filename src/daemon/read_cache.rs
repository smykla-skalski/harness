use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, TryLockError};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(test)]
use tokio::task::JoinError;
use tokio::task::spawn_blocking;

use crate::errors::{CliError, CliErrorKind};

use super::db::{DaemonDb, canonical_db_unavailable};

pub(crate) const READ_DB_LOCK_WAIT: Duration = Duration::from_secs(5);
pub(crate) const READ_DB_LOCK_POLL: Duration = Duration::from_millis(50);

pub(crate) async fn run_canonical_db_read<T, FDb>(
    db_slot: &Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    db_path: Option<PathBuf>,
    read_name: &'static str,
    db_read: FDb,
) -> Result<T, CliError>
where
    T: Send + 'static,
    FDb: FnOnce(&DaemonDb) -> Result<T, CliError> + Send + 'static,
{
    spawn_canonical_db_read(
        db_slot.get().cloned(),
        db_path,
        read_name,
        READ_DB_LOCK_WAIT,
        READ_DB_LOCK_POLL,
        db_read,
    )
    .await
}

#[cfg(test)]
async fn run_preferred_db_read_with_limits<T, FDb, FFallback>(
    db_slot: &Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    read_name: &'static str,
    wait_limit: Duration,
    poll_interval: Duration,
    db_read: FDb,
    fallback: FFallback,
) -> Result<T, CliError>
where
    T: Send + 'static,
    FDb: FnOnce(&DaemonDb) -> Result<T, CliError> + Send + 'static,
    FFallback: FnOnce() -> Result<T, CliError>,
{
    let Some(db) = db_slot.get().cloned() else {
        return fallback();
    };

    let outcome = spawn_preferred_db_read(db, read_name, wait_limit, poll_interval, db_read).await;
    handle_db_read_outcome(outcome, read_name, wait_limit, fallback)
}

#[cfg(test)]
async fn run_canonical_db_read_with_limits<T, FDb>(
    db_slot: &Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    db_path: Option<PathBuf>,
    read_name: &'static str,
    wait_limit: Duration,
    poll_interval: Duration,
    db_read: FDb,
) -> Result<T, CliError>
where
    T: Send + 'static,
    FDb: FnOnce(&DaemonDb) -> Result<T, CliError> + Send + 'static,
{
    spawn_canonical_db_read(
        db_slot.get().cloned(),
        db_path,
        read_name,
        wait_limit,
        poll_interval,
        db_read,
    )
    .await
}

async fn spawn_canonical_db_read<T, FDb>(
    db: Option<Arc<Mutex<DaemonDb>>>,
    db_path: Option<PathBuf>,
    read_name: &'static str,
    wait_limit: Duration,
    poll_interval: Duration,
    db_read: FDb,
) -> Result<T, CliError>
where
    T: Send + 'static,
    FDb: FnOnce(&DaemonDb) -> Result<T, CliError> + Send + 'static,
{
    spawn_blocking(move || {
        try_canonical_db_read(db, db_path, read_name, wait_limit, poll_interval, db_read)
    })
    .await
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "run canonical daemon read task for {read_name}: {error}"
        )))
    })?
}

#[cfg(test)]
async fn spawn_preferred_db_read<T, FDb>(
    db: Arc<Mutex<DaemonDb>>,
    read_name: &'static str,
    wait_limit: Duration,
    poll_interval: Duration,
    db_read: FDb,
) -> Result<DbReadOutcome<T>, JoinError>
where
    T: Send + 'static,
    FDb: FnOnce(&DaemonDb) -> Result<T, CliError> + Send + 'static,
{
    spawn_blocking(move || {
        try_db_read_with_wait(&db, read_name, wait_limit, poll_interval, db_read)
    })
    .await
}

#[cfg(test)]
fn handle_db_read_outcome<T, FFallback>(
    outcome: Result<DbReadOutcome<T>, JoinError>,
    read_name: &'static str,
    wait_limit: Duration,
    fallback: FFallback,
) -> Result<T, CliError>
where
    FFallback: FnOnce() -> Result<T, CliError>,
{
    let outcome = match outcome {
        Ok(outcome) => outcome,
        Err(error) => return handle_db_read_task_failure(&error, read_name, fallback),
    };

    match outcome {
        DbReadOutcome::Ready(result) => result,
        DbReadOutcome::Fallback => handle_db_read_timeout(read_name, wait_limit, fallback),
    }
}

#[cfg(test)]
enum DbReadOutcome<T> {
    Ready(Result<T, CliError>),
    Fallback,
}

#[expect(
    clippy::cognitive_complexity,
    reason = "shared-db retry plus standalone-db fallback are intentionally coupled"
)]
fn try_canonical_db_read<T, FDb>(
    db: Option<Arc<Mutex<DaemonDb>>>,
    db_path: Option<PathBuf>,
    read_name: &'static str,
    wait_limit: Duration,
    poll_interval: Duration,
    db_read: FDb,
) -> Result<T, CliError>
where
    FDb: FnOnce(&DaemonDb) -> Result<T, CliError>,
{
    let mut db_read = Some(db_read);

    if let Some(db) = db {
        let started = Instant::now();
        loop {
            match db.try_lock() {
                Ok(db_guard) => {
                    let read = db_read.take().expect("db read closure should run once");
                    return read(&db_guard);
                }
                Err(TryLockError::WouldBlock) => {
                    let elapsed = started.elapsed();
                    if elapsed >= wait_limit {
                        tracing::warn!(
                            read = read_name,
                            wait_ms = u64::try_from(wait_limit.as_millis()).unwrap_or(u64::MAX),
                            "daemon read opening standalone canonical connection after db lock wait timeout"
                        );
                        break;
                    }
                    let remaining = wait_limit.saturating_sub(elapsed);
                    thread::sleep(remaining.min(poll_interval));
                }
                Err(TryLockError::Poisoned(error)) => {
                    return Err(CliErrorKind::workflow_io(format!(
                        "lock daemon db for {read_name}: {error}"
                    ))
                    .into());
                }
            }
        }
    }

    let path = db_path.ok_or_else(|| canonical_db_unavailable(read_name))?;
    let standalone_db = DaemonDb::open(&path).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "open canonical daemon database for {read_name}: {error}"
        ))
    })?;
    let read = db_read.take().expect("db read closure should run once");
    read(&standalone_db)
}

#[cfg(test)]
fn try_db_read_with_wait<T, FDb>(
    db: &Arc<Mutex<DaemonDb>>,
    read_name: &'static str,
    wait_limit: Duration,
    poll_interval: Duration,
    db_read: FDb,
) -> DbReadOutcome<T>
where
    FDb: FnOnce(&DaemonDb) -> Result<T, CliError>,
{
    let started = Instant::now();
    let mut db_read = Some(db_read);

    loop {
        match db.try_lock() {
            Ok(db_guard) => {
                let read = db_read.take().expect("db read closure should run once");
                return DbReadOutcome::Ready(read(&db_guard));
            }
            Err(TryLockError::WouldBlock) => {
                let elapsed = started.elapsed();
                if elapsed >= wait_limit {
                    return DbReadOutcome::Fallback;
                }
                let remaining = wait_limit.saturating_sub(elapsed);
                thread::sleep(remaining.min(poll_interval));
            }
            Err(TryLockError::Poisoned(error)) => {
                return DbReadOutcome::Ready(Err(CliErrorKind::workflow_io(format!(
                    "lock daemon db for {read_name}: {error}"
                ))
                .into()));
            }
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
#[cfg(test)]
fn handle_db_read_timeout<T, FFallback>(
    read_name: &'static str,
    wait_limit: Duration,
    fallback: FFallback,
) -> Result<T, CliError>
where
    FFallback: FnOnce() -> Result<T, CliError>,
{
    tracing::warn!(
        read = read_name,
        wait_ms = u64::try_from(wait_limit.as_millis()).unwrap_or(u64::MAX),
        "daemon read falling back after db lock wait timeout"
    );
    fallback()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
#[cfg(test)]
fn handle_db_read_task_failure<T, FFallback>(
    error: &JoinError,
    read_name: &'static str,
    fallback: FFallback,
) -> Result<T, CliError>
where
    FFallback: FnOnce() -> Result<T, CliError>,
{
    tracing::warn!(
        %error,
        read = read_name,
        "daemon read task failed; using fallback"
    );
    fallback()
}

#[cfg(test)]
mod tests {
    use super::{run_canonical_db_read_with_limits, run_preferred_db_read_with_limits};
    use crate::daemon::db::DaemonDb;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Barrier, Mutex, OnceLock};
    use std::time::Duration;
    use tempfile::tempdir;

    #[tokio::test]
    async fn waits_for_db_before_using_fallback() {
        let slot = Arc::new(OnceLock::new());
        let db = Arc::new(Mutex::new(
            DaemonDb::open_in_memory().expect("open in-memory db"),
        ));
        slot.set(Arc::clone(&db)).expect("install db");

        let barrier = Arc::new(Barrier::new(2));
        let barrier_clone = Arc::clone(&barrier);
        let db_clone = Arc::clone(&db);
        let holder = std::thread::spawn(move || {
            let _guard = db_clone.lock().expect("db lock");
            barrier_clone.wait();
            std::thread::sleep(Duration::from_millis(75));
        });
        barrier.wait();

        let fallback_calls = Arc::new(AtomicUsize::new(0));
        let fallback_counter = Arc::clone(&fallback_calls);
        let value = run_preferred_db_read_with_limits(
            &slot,
            "session detail",
            Duration::from_millis(250),
            Duration::from_millis(10),
            |_| Ok(7_u32),
            move || {
                fallback_counter.fetch_add(1, Ordering::SeqCst);
                Ok(11_u32)
            },
        )
        .await
        .expect("db read result");

        holder.join().expect("holder thread");

        assert_eq!(value, 7);
        assert_eq!(fallback_calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn falls_back_after_wait_limit_expires() {
        let slot = Arc::new(OnceLock::new());
        let db = Arc::new(Mutex::new(
            DaemonDb::open_in_memory().expect("open in-memory db"),
        ));
        slot.set(Arc::clone(&db)).expect("install db");

        let barrier = Arc::new(Barrier::new(2));
        let barrier_clone = Arc::clone(&barrier);
        let db_clone = Arc::clone(&db);
        let holder = std::thread::spawn(move || {
            let _guard = db_clone.lock().expect("db lock");
            barrier_clone.wait();
            std::thread::sleep(Duration::from_millis(150));
        });
        barrier.wait();

        let fallback_calls = Arc::new(AtomicUsize::new(0));
        let fallback_counter = Arc::clone(&fallback_calls);
        let value = run_preferred_db_read_with_limits(
            &slot,
            "session detail",
            Duration::from_millis(20),
            Duration::from_millis(5),
            |_| Ok(7_u32),
            move || {
                fallback_counter.fetch_add(1, Ordering::SeqCst);
                Ok(11_u32)
            },
        )
        .await
        .expect("fallback result");

        holder.join().expect("holder thread");

        assert_eq!(value, 11);
        assert_eq!(fallback_calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn canonical_reads_fail_when_db_missing() {
        let slot = Arc::new(OnceLock::new());
        let error = run_canonical_db_read_with_limits(
            &slot,
            None,
            "projects",
            Duration::from_millis(20),
            Duration::from_millis(5),
            |_| Ok(7_u32),
        )
        .await
        .expect_err("missing canonical db should fail");

        assert!(
            error
                .to_string()
                .contains("daemon canonical database unavailable for projects")
        );
    }

    #[tokio::test]
    async fn canonical_reads_fail_after_wait_limit_expires() {
        let slot = Arc::new(OnceLock::new());
        let db = Arc::new(Mutex::new(
            DaemonDb::open_in_memory().expect("open in-memory db"),
        ));
        slot.set(Arc::clone(&db)).expect("install db");

        let barrier = Arc::new(Barrier::new(2));
        let barrier_clone = Arc::clone(&barrier);
        let db_clone = Arc::clone(&db);
        let holder = std::thread::spawn(move || {
            let _guard = db_clone.lock().expect("db lock");
            barrier_clone.wait();
            std::thread::sleep(Duration::from_millis(150));
        });
        barrier.wait();

        let error = run_canonical_db_read_with_limits(
            &slot,
            None,
            "session detail",
            Duration::from_millis(20),
            Duration::from_millis(5),
            |_| Ok(7_u32),
        )
        .await
        .expect_err("timed out canonical db read should fail");

        holder.join().expect("holder thread");

        assert!(
            error
                .to_string()
                .contains("daemon canonical database unavailable for session detail")
        );
    }

    #[tokio::test]
    async fn canonical_reads_reopen_standalone_db_after_wait_limit_expires() {
        let tmp = tempdir().expect("tempdir");
        let db_path = tmp.path().join("harness.db");
        let file_db = DaemonDb::open(&db_path).expect("open file db");
        let slot = Arc::new(OnceLock::new());
        let db = Arc::new(Mutex::new(file_db));
        slot.set(Arc::clone(&db)).expect("install db");

        let barrier = Arc::new(Barrier::new(2));
        let barrier_clone = Arc::clone(&barrier);
        let db_clone = Arc::clone(&db);
        let holder = std::thread::spawn(move || {
            let _guard = db_clone.lock().expect("db lock");
            barrier_clone.wait();
            std::thread::sleep(Duration::from_millis(150));
        });
        barrier.wait();

        let value = run_canonical_db_read_with_limits(
            &slot,
            Some(db_path),
            "session detail",
            Duration::from_millis(20),
            Duration::from_millis(5),
            |_| Ok(7_u32),
        )
        .await
        .expect("standalone canonical read result");

        holder.join().expect("holder thread");

        assert_eq!(value, 7);
    }
}
