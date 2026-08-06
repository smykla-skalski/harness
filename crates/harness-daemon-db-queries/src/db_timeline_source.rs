//! Adapts [`DaemonDb`] to `harness_timeline`'s [`TimelineDbSource`] contract.
//!
//! `TimelineDbSource` (owned by `harness-timeline`) and `DaemonDb` (owned by
//! `harness-daemon-db-core`) are both foreign to this crate, so implementing
//! the trait directly for the struct would trip Rust's orphan rule. This
//! newtype wrapper is local here, so implementing the foreign trait for it
//! has no such problem; it delegates to the session/conversation query
//! traits this crate already owns.

use harness_daemon_db_core::DaemonDb;
use harness_kernel::errors::CliError;
use harness_protocol::agent::ConversationEvent;
use harness_protocol::session::{SessionLogEntry, TaskCheckpoint};
use harness_timeline::TimelineDbSource;

use crate::conversation::DaemonDbConversation;
use crate::session_data::SessionCoreQueries;

pub struct DaemonDbTimelineHandle<'a>(pub &'a DaemonDb);

impl TimelineDbSource for DaemonDbTimelineHandle<'_> {
    fn load_session_log(&self, session_id: &str) -> Result<Vec<SessionLogEntry>, CliError> {
        <DaemonDb as SessionCoreQueries>::load_session_log(self.0, session_id)
    }

    fn load_task_checkpoints(
        &self,
        session_id: &str,
        task_id: &str,
    ) -> Result<Vec<TaskCheckpoint>, CliError> {
        <DaemonDb as SessionCoreQueries>::load_task_checkpoints(self.0, session_id, task_id)
    }

    fn load_conversation_events(
        &self,
        session_id: &str,
        agent_id: &str,
    ) -> Result<Vec<ConversationEvent>, CliError> {
        DaemonDbConversation::load_conversation_events(self.0, session_id, agent_id)
    }
}
