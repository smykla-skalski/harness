use serde::{Deserialize, Serialize};

use crate::daemon::agent_acp::AcpAgentSnapshot;
use crate::daemon::agent_tui::AgentTuiSnapshot;
use crate::session::types::{HarnessSessionId, ManagedAgentId, SessionAgentId};

use super::CodexRunSnapshot;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", content = "snapshot")]
pub enum ManagedAgentSnapshot {
    Terminal(AgentTuiSnapshot),
    Codex(CodexRunSnapshot),
    Acp(AcpAgentSnapshot),
}

impl ManagedAgentSnapshot {
    /// Legacy transport identifier used by existing managed-agent routes.
    ///
    /// For terminal agents this is `tui_id`, for codex it is `run_id`, and for
    /// ACP it is `acp_id`. Prefer [`Self::managed_agent_id`] or
    /// [`Self::session_agent_id`] in new code when the identity class matters.
    #[must_use]
    pub fn agent_id(&self) -> &str {
        match self {
            Self::Terminal(snapshot) => &snapshot.tui_id,
            Self::Codex(snapshot) => &snapshot.run_id,
            Self::Acp(snapshot) => &snapshot.acp_id,
        }
    }

    #[must_use]
    pub fn managed_agent_id(&self) -> ManagedAgentId {
        ManagedAgentId::from(self.agent_id())
    }

    #[must_use]
    pub fn session_agent_id(&self) -> Option<SessionAgentId> {
        match self {
            Self::Terminal(snapshot) => Some(SessionAgentId::from(snapshot.agent_id.as_str())),
            Self::Codex(_) => None,
            Self::Acp(snapshot) => Some(SessionAgentId::from(snapshot.agent_id.as_str())),
        }
    }

    #[must_use]
    pub fn harness_session_id(&self) -> HarnessSessionId {
        HarnessSessionId::from(self.session_id())
    }

    #[must_use]
    pub fn session_id(&self) -> &str {
        match self {
            Self::Terminal(snapshot) => &snapshot.session_id,
            Self::Codex(snapshot) => &snapshot.session_id,
            Self::Acp(snapshot) => &snapshot.session_id,
        }
    }

    #[must_use]
    pub fn updated_at(&self) -> &str {
        match self {
            Self::Terminal(snapshot) => &snapshot.updated_at,
            Self::Codex(snapshot) => &snapshot.updated_at,
            Self::Acp(snapshot) => &snapshot.updated_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManagedAgentListResponse {
    pub agents: Vec<ManagedAgentSnapshot>,
}

#[cfg(test)]
mod tests {
    use crate::daemon::agent_acp::AcpAgentSnapshot;
    use crate::daemon::agent_tui::{
        AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, TerminalScreenSnapshot,
    };
    use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot, CodexRunStatus};
    use crate::session::types::{AgentStatus, HarnessSessionId, ManagedAgentId, SessionAgentId};

    use super::ManagedAgentSnapshot;

    #[test]
    fn managed_agent_snapshot_separates_transport_and_session_agent_ids() {
        let terminal = ManagedAgentSnapshot::Terminal(AgentTuiSnapshot {
            tui_id: "tui-1".into(),
            session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
            agent_id: "worker-1".into(),
            runtime: "claude".into(),
            status: AgentTuiStatus::Running,
            argv: Vec::new(),
            project_dir: "/tmp/project".into(),
            size: AgentTuiSize { rows: 24, cols: 80 },
            screen: TerminalScreenSnapshot {
                rows: 24,
                cols: 80,
                cursor_row: 0,
                cursor_col: 0,
                text: "ready".into(),
            },
            transcript_path: "/tmp/transcript".into(),
            exit_code: None,
            signal: None,
            error: None,
            created_at: "2026-05-06T00:00:00Z".into(),
            updated_at: "2026-05-06T00:00:00Z".into(),
        });
        assert_eq!(terminal.managed_agent_id(), ManagedAgentId::from("tui-1"));
        assert_eq!(
            terminal.session_agent_id(),
            Some(SessionAgentId::from("worker-1"))
        );
        assert_eq!(
            terminal.harness_session_id(),
            HarnessSessionId::from("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
        );

        let codex = ManagedAgentSnapshot::Codex(CodexRunSnapshot {
            run_id: "run-1".into(),
            session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
            project_dir: "/tmp/project".into(),
            thread_id: None,
            turn_id: None,
            mode: CodexRunMode::Report,
            status: CodexRunStatus::Running,
            prompt: "investigate".into(),
            latest_summary: None,
            final_message: None,
            error: None,
            pending_approvals: Vec::new(),
            created_at: "2026-05-06T00:00:00Z".into(),
            updated_at: "2026-05-06T00:00:00Z".into(),
            model: None,
            effort: None,
        });
        assert_eq!(codex.managed_agent_id(), ManagedAgentId::from("run-1"));
        assert_eq!(codex.session_agent_id(), None);
        assert_eq!(
            codex.harness_session_id(),
            HarnessSessionId::from("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
        );

        let acp = ManagedAgentSnapshot::Acp(AcpAgentSnapshot {
            acp_id: "acp-1".into(),
            session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
            agent_id: "worker-2".into(),
            display_name: "Copilot".into(),
            status: AgentStatus::Active,
            pid: 42,
            pgid: 42,
            project_dir: "/tmp/project".into(),
            process_key: "proc-1".into(),
            pending_permissions: 0,
            permission_queue_depth: 0,
            pending_permission_batches: Vec::new(),
            permission_mode: String::new(),
            permission_log_path: None,
            terminal_count: 0,
            created_at: "2026-05-06T00:00:00Z".into(),
            updated_at: "2026-05-06T00:00:00Z".into(),
        });
        assert_eq!(acp.managed_agent_id(), ManagedAgentId::from("acp-1"));
        assert_eq!(
            acp.session_agent_id(),
            Some(SessionAgentId::from("worker-2"))
        );
        assert_eq!(
            acp.harness_session_id(),
            HarnessSessionId::from("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
        );
    }
}
