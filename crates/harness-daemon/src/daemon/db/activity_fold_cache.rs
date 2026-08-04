use std::collections::HashMap;

use super::daemon_snapshot;

/// Cached running activity fold for one `(session_id, agent_id)` pair.
pub(crate) struct ActivityFoldEntry {
    /// Highest conversation sequence already folded into `accumulator`.
    pub(crate) last_sequence: i64,
    pub(crate) accumulator: daemon_snapshot::AgentActivityAccumulator,
}

/// In-memory activity folds keyed by `(session_id, agent_id)`.
pub(crate) type ActivityFoldCache = HashMap<(String, String), ActivityFoldEntry>;
