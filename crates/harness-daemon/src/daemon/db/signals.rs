//! `SignalIndexQueries` itself lives in `harness-daemon-db-queries` now (see
//! that crate's `signals` module) - only the orphan-rule forwarding impl
//! stays here, since it needs `DaemonDbOwnedHandle`, a `harness-daemon`-local
//! wrapper type.

use harness_daemon_db_queries::SignalIndexQueries;
use harness_kernel::errors::CliError;
use harness_protocol::session::{SessionSignalRecord, SessionState};

use super::DaemonDb;

// `harness-daemon-snapshot` depends on this trait, not on `DaemonDb` itself
// (see that crate's `storage` module). `DaemonDb` moved into its own crate
// for #1231, so this trait and `DaemonDb` are both foreign here now; the
// local `DaemonDbOwnedHandle` newtype (`crate::daemon::db_handle`) is what
// implements it instead, the same orphan-rule workaround
// `harness_daemon_db_queries::DaemonDbTimelineHandle` uses for
// `TimelineDbSource`.
//
// Fully qualifies through `SignalIndexQueries` rather than `Self::`: once
// this trait's methods share a name with `SignalIndexQueries`'s, bare
// `Self::method` resolves to this very impl and cycles instead of forwarding.
impl harness_daemon_snapshot::SessionSignalQueries
    for crate::daemon::db_handle::DaemonDbOwnedHandle
{
    fn load_signals(&self, session_id: &str) -> Result<Vec<SessionSignalRecord>, CliError> {
        <DaemonDb as SignalIndexQueries>::load_signals(&self.0, session_id)
    }

    fn session_has_shared_runtime_signal_dir(
        &self,
        state: &SessionState,
    ) -> Result<bool, CliError> {
        <DaemonDb as SignalIndexQueries>::session_has_shared_runtime_signal_dir(&self.0, state)
    }

    fn sync_signal_index(
        &self,
        session_id: &str,
        signals: &[SessionSignalRecord],
    ) -> Result<(), CliError> {
        <DaemonDb as SignalIndexQueries>::sync_signal_index(&self.0, session_id, signals)
    }
}
