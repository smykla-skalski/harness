use std::future::Future;

use harness_kernel::errors::CliError;
use harness_protocol::managed_agents::codex::CodexRunSnapshot;

/// Codex-run persistence the controller needs, independent of the concrete
/// database type. `harness-daemon` implements this for its own async
/// database handle, delegating to the SQL it already has - this crate never
/// needs to know the storage mechanism, only the port.
pub trait AsyncCodexRunStorage: Send + Sync {
    /// # Errors
    /// Returns [`CliError`] on SQL or serialization failures.
    fn save_codex_run(
        &self,
        snapshot: &CodexRunSnapshot,
    ) -> impl Future<Output = Result<(), CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    fn codex_run(
        &self,
        run_id: &str,
    ) -> impl Future<Output = Result<Option<CodexRunSnapshot>, CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    fn list_codex_runs(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<Vec<CodexRunSnapshot>, CliError>> + Send;
}
