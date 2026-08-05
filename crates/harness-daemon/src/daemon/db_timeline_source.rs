//! Adapts [`DaemonDb`] to `harness_timeline`'s [`TimelineDbSource`] contract.
//!
//! `TimelineDbSource` and `DaemonDb` are both defined outside `harness-daemon`
//! once `DaemonDb` moves into its own crate for #1231, so `harness-daemon`
//! can no longer implement the trait directly for the type (Rust's orphan
//! rule needs one of the two to be local). This newtype wrapper is local to
//! `harness-daemon`, so implementing the foreign trait for it has no such
//! problem; it delegates to the session/conversation extension traits that
//! must stay in this crate.

use crate::agents::runtime::event::ConversationEvent;
use crate::daemon::db::DaemonDbConversation;
use crate::daemon::db::{DaemonDb, SessionCoreQueries};
use crate::session::types::{SessionLogEntry, TaskCheckpoint};
use harness_kernel::errors::CliError;
use harness_timeline::TimelineDbSource;

pub(crate) struct DaemonDbTimelineHandle<'a>(pub(crate) &'a DaemonDb);

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
