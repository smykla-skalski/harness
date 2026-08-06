use harness_daemon_codex::AsyncCodexRunStorage;
use harness_kernel::errors::CliError;
use harness_protocol::managed_agents::codex::CodexRunSnapshot;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::AsyncRuntimeSnapshotQueries;
use crate::daemon::db_handle::AsyncDaemonDbHandle;

impl AsyncCodexRunStorage for AsyncDaemonDbHandle {
    async fn save_codex_run(&self, snapshot: &CodexRunSnapshot) -> Result<(), CliError> {
        <AsyncDaemonDb as AsyncRuntimeSnapshotQueries>::save_codex_run(&self.0, snapshot).await
    }

    async fn codex_run(&self, run_id: &str) -> Result<Option<CodexRunSnapshot>, CliError> {
        <AsyncDaemonDb as AsyncRuntimeSnapshotQueries>::codex_run(&self.0, run_id).await
    }

    async fn list_codex_runs(&self, session_id: &str) -> Result<Vec<CodexRunSnapshot>, CliError> {
        <AsyncDaemonDb as AsyncRuntimeSnapshotQueries>::list_codex_runs(&self.0, session_id).await
    }
}
