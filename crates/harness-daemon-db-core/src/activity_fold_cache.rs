use std::collections::HashMap;

use super::daemon_snapshot;

/// Cached running activity fold for one `(session_id, agent_id)` pair.
pub struct ActivityFoldEntry {
    /// Highest conversation sequence already folded into `accumulator`.
    pub last_sequence: i64,
    pub accumulator: daemon_snapshot::AgentActivityAccumulator,
}

/// In-memory activity folds keyed by `(session_id, agent_id)`.
pub type ActivityFoldCache = HashMap<(String, String), ActivityFoldEntry>;
