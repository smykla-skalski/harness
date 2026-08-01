use crate::session::adopter::AdoptionOutcome;
use harness_kernel::errors::CliError;

/// Register an adopted session in the daemon `SQLite` DB (sync path).
///
/// # Errors
/// Returns `CliError` on DB failures.
pub fn adopt_session_record(
    outcome: &AdoptionOutcome,
    db: &super::db::DaemonDb,
) -> Result<(), CliError> {
    harness_daemon_session_service::adopt_session_record(outcome, db)
}

/// Register an adopted session in the daemon `SQLite` DB (async path).
///
/// # Errors
/// Returns `CliError` on DB failures.
pub(crate) async fn adopt_session_record_async(
    outcome: &AdoptionOutcome,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<(), CliError> {
    harness_daemon_session_service::adopt_session_record_async(outcome, async_db).await
}
