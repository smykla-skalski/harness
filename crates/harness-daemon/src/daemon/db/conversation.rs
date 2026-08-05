//! `DaemonDbConversation` itself lives in `harness-daemon-db-queries` now
//! (see that crate's `conversation` module) - only the orphan-rule forwarding
//! impl stays here, since it needs `DaemonDbOwnedHandle`, a
//! `harness-daemon`-local wrapper type.

use harness_daemon_db_queries::DaemonDbConversation;
use harness_kernel::errors::CliError;
use harness_session::wire::AgentToolActivitySummary;

// `harness-daemon-snapshot` depends on this trait, not on `DaemonDb` itself
// (see that crate's `storage` module). `DaemonDb` moved into its own crate
// for #1231, so this trait and `DaemonDb` are both foreign here now; the
// local `DaemonDbOwnedHandle` newtype (`crate::daemon::db_handle`) is what
// implements it instead, the same orphan-rule workaround
// `daemon::db_timeline_source::DaemonDbTimelineHandle` already uses for
// `TimelineDbSource`.
impl harness_daemon_snapshot::ConversationQueries
    for crate::daemon::db_handle::DaemonDbOwnedHandle
{
    fn load_agent_activity(
        &self,
        session_id: &str,
    ) -> Result<Vec<AgentToolActivitySummary>, CliError> {
        DaemonDbConversation::load_agent_activity(&self.0, session_id)
    }
}
