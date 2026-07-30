//! Storage seam this crate reaches through, never around.
//!
//! `harness-daemon`'s `DaemonDb` implements both traits below (see
//! `daemon/db/signals.rs` and `daemon/db/conversation.rs`) and depends on
//! this crate; this crate never names `DaemonDb` itself, which is what makes
//! that dependency direction possible. Naming and grouping follow the
//! session/conversation/signal grouping settled on for the rest of `db`'s
//! extension surface, narrowed to exactly the reads and writes a session
//! detail snapshot needs.

use harness_kernel::errors::CliError;
use harness_session::types::{SessionSignalRecord, SessionState};
use harness_session::wire::AgentToolActivitySummary;

/// Signal-index reads and the refresh write a session detail snapshot needs.
pub trait SessionSignalQueries {
    /// # Errors
    /// Returns [`CliError`] on query failure.
    fn load_signals(&self, session_id: &str) -> Result<Vec<SessionSignalRecord>, CliError>;

    /// # Errors
    /// Returns [`CliError`] on query failure.
    fn session_has_shared_runtime_signal_dir(
        &self,
        state: &SessionState,
    ) -> Result<bool, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    fn sync_signal_index(
        &self,
        session_id: &str,
        signals: &[SessionSignalRecord],
    ) -> Result<(), CliError>;
}

/// Cached agent-activity reads a session detail snapshot needs.
pub trait ConversationQueries {
    /// # Errors
    /// Returns [`CliError`] on query failure.
    fn load_agent_activity(
        &self,
        session_id: &str,
    ) -> Result<Vec<AgentToolActivitySummary>, CliError>;
}

/// Both halves of the storage seam, combined so a snapshot function that
/// needs signals and activity together can take one `&dyn` reference instead
/// of naming a concrete db type or threading two separate bounds.
///
/// Blanket-implemented for anything implementing both traits, so `DaemonDb`
/// needs no third impl block to satisfy it.
pub trait SnapshotStorage: SessionSignalQueries + ConversationQueries {}

impl<T: SessionSignalQueries + ConversationQueries + ?Sized> SnapshotStorage for T {}
