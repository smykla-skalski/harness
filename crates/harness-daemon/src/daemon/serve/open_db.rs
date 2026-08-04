use std::path::Path;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::daemon::db_open::DaemonDbOpen;
use crate::daemon::state;
use harness_kernel::errors::CliError;

pub(crate) fn open_daemon_db(path: &Path) -> Result<DaemonDb, CliError> {
    DaemonDb::open(path).inspect_err(|error| {
        let message = format!("failed to open daemon database: {error}");
        let _ = state::append_event("warn", &message);
    })
}

pub(crate) async fn open_daemon_async_db(path: &Path) -> Result<AsyncDaemonDb, CliError> {
    AsyncDaemonDb::connect(path).await.inspect_err(|error| {
        let message = format!("failed to open daemon async database pool: {error}");
        let _ = state::append_event("warn", &message);
    })
}
