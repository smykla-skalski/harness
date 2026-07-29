use crate::daemon::state;
use harness_kernel::errors::CliError;

/// Resolve the identity at startup rather than on the first client read, so a
/// host that cannot mint one fails while the operator is still watching.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(super) fn resolve_daemon_identity() -> Result<(), CliError> {
    let identity = state::ensure_daemon_identity()?;
    tracing::info!(
        daemon_id = identity.daemon_id,
        daemon_name = identity.name,
        "daemon identity resolved",
    );
    Ok(())
}
