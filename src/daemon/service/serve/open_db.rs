use std::path::Path;

use crate::daemon::service::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::state;
use crate::errors::CliError;

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
