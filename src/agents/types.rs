use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(crate) struct AgentSessionRegistry {
    pub(crate) updated_at: String,
    pub(crate) current: std::collections::BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct AgentLedgerEvent {
    pub(crate) sequence: u64,
    pub(crate) recorded_at: String,
    pub(crate) agent: String,
    pub(crate) session_id: String,
    pub(crate) skill: String,
    pub(crate) event: String,
    pub(crate) hook: String,
    pub(crate) decision: Option<String>,
    pub(crate) cwd: String,
    pub(crate) payload: Value,
}
