use harness_agents::runtime::event::ConversationEvent;
use harness_kernel::errors::CliError;
use harness_protocol::session::{SessionLogEntry, TaskCheckpoint};

/// The subset of a daemon database's read surface a timeline needs to
/// rebuild itself from durable storage instead of the filesystem index.
///
/// Defined here rather than depending on `harness-daemon`'s own `DaemonDb`
/// so this crate never depends back on its own dependent: the daemon's `db`
/// module implements this trait for `DaemonDb` and hands a `&dyn` reference
/// in, keeping the dependency edge one-directional.
pub trait TimelineDbSource {
    /// # Errors
    /// Returns [`CliError`] on query failure.
    fn load_session_log(&self, session_id: &str) -> Result<Vec<SessionLogEntry>, CliError>;

    /// # Errors
    /// Returns [`CliError`] on query failure.
    fn load_task_checkpoints(
        &self,
        session_id: &str,
        task_id: &str,
    ) -> Result<Vec<TaskCheckpoint>, CliError>;

    /// # Errors
    /// Returns [`CliError`] on query failure.
    fn load_conversation_events(
        &self,
        session_id: &str,
        agent_id: &str,
    ) -> Result<Vec<ConversationEvent>, CliError>;
}
