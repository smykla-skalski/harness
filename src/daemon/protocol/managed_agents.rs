use serde::{Deserialize, Serialize};

use crate::daemon::agent_tui::AgentTuiSnapshot;

use super::CodexRunSnapshot;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", content = "snapshot")]
pub enum ManagedAgentSnapshot {
    Terminal(AgentTuiSnapshot),
    Codex(CodexRunSnapshot),
}

impl ManagedAgentSnapshot {
    #[must_use]
    pub fn agent_id(&self) -> &str {
        match self {
            Self::Terminal(snapshot) => &snapshot.tui_id,
            Self::Codex(snapshot) => &snapshot.run_id,
        }
    }

    #[must_use]
    pub fn session_id(&self) -> &str {
        match self {
            Self::Terminal(snapshot) => &snapshot.session_id,
            Self::Codex(snapshot) => &snapshot.session_id,
        }
    }

    #[must_use]
    pub fn updated_at(&self) -> &str {
        match self {
            Self::Terminal(snapshot) => &snapshot.updated_at,
            Self::Codex(snapshot) => &snapshot.updated_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManagedAgentListResponse {
    pub agents: Vec<ManagedAgentSnapshot>,
}
