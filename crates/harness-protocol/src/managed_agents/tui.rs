use serde::{Deserialize, Serialize};

use crate::session::SessionRole;

pub const DEFAULT_AGENT_TUI_ROWS: u16 = 30;
pub const DEFAULT_AGENT_TUI_COLS: u16 = 120;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiSize {
    pub rows: u16,
    pub cols: u16,
}

impl Default for AgentTuiSize {
    fn default() -> Self {
        Self {
            rows: DEFAULT_AGENT_TUI_ROWS,
            cols: DEFAULT_AGENT_TUI_COLS,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentTuiStatus {
    Starting,
    Running,
    Exited,
    Failed,
    Stopped,
}

impl AgentTuiStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Exited => "exited",
            Self::Failed => "failed",
            Self::Stopped => "stopped",
        }
    }

    /// Parse the status stored by daemon persistence layers.
    ///
    /// # Errors
    /// Returns an error when the status is not part of the wire contract.
    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "starting" => Ok(Self::Starting),
            "running" => Ok(Self::Running),
            "exited" => Ok(Self::Exited),
            "failed" => Ok(Self::Failed),
            "stopped" => Ok(Self::Stopped),
            _ => Err(format!("unknown terminal agent status '{value}'")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalScreenSnapshot {
    pub rows: u16,
    pub cols: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub text: String,
}

impl TerminalScreenSnapshot {
    #[must_use]
    pub const fn size(&self) -> AgentTuiSize {
        AgentTuiSize {
            rows: self.rows,
            cols: self.cols,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiStartRequest {
    pub runtime: String,
    #[serde(default = "default_agent_tui_role")]
    pub role: SessionRole,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback_role: Option<SessionRole>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub argv: Vec<String>,
    #[serde(default = "default_agent_tui_rows")]
    pub rows: u16,
    #[serde(default = "default_agent_tui_cols")]
    pub cols: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub persona: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub board_item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_execution_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "core::ops::Not::not")]
    pub allow_custom_model: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiResizeRequest {
    pub rows: u16,
    pub cols: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiListResponse {
    pub tuis: Vec<AgentTuiSnapshot>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiSnapshot {
    pub tui_id: String,
    pub session_id: String,
    pub agent_id: String,
    pub runtime: String,
    pub status: AgentTuiStatus,
    pub argv: Vec<String>,
    pub project_dir: String,
    pub size: AgentTuiSize,
    pub screen: TerminalScreenSnapshot,
    pub transcript_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signal: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

fn default_agent_tui_role() -> SessionRole {
    SessionRole::Worker
}

const fn default_agent_tui_rows() -> u16 {
    DEFAULT_AGENT_TUI_ROWS
}

const fn default_agent_tui_cols() -> u16 {
    DEFAULT_AGENT_TUI_COLS
}

#[cfg(test)]
mod tests {
    use super::{
        AgentTuiSize, AgentTuiStartRequest, AgentTuiStatus, DEFAULT_AGENT_TUI_COLS,
        DEFAULT_AGENT_TUI_ROWS,
    };
    use crate::session::SessionRole;

    #[test]
    fn start_request_defaults_match_daemon_wire_contract() {
        let request: AgentTuiStartRequest = serde_json::from_value(serde_json::json!({
            "runtime": "codex"
        }))
        .expect("decode terminal start request");

        assert_eq!(request.role, SessionRole::Worker);
        assert_eq!(request.rows, DEFAULT_AGENT_TUI_ROWS);
        assert_eq!(request.cols, DEFAULT_AGENT_TUI_COLS);
        assert!(request.argv.is_empty());
        assert!(!request.allow_custom_model);
    }

    #[test]
    fn start_request_serialization_preserves_optional_field_policy() {
        let request = AgentTuiStartRequest {
            runtime: "codex".into(),
            role: SessionRole::Reviewer,
            fallback_role: None,
            capabilities: Vec::new(),
            name: None,
            prompt: None,
            project_dir: None,
            argv: Vec::new(),
            rows: 40,
            cols: 160,
            persona: None,
            task_id: None,
            board_item_id: None,
            workflow_execution_id: None,
            model: None,
            effort: None,
            allow_custom_model: false,
        };

        let value = serde_json::to_value(request).expect("serialize terminal start request");
        assert_eq!(value["runtime"], "codex");
        assert_eq!(value["role"], "reviewer");
        assert_eq!(value["rows"], 40);
        assert_eq!(value["cols"], 160);
        assert_eq!(value["capabilities"], serde_json::json!([]));
        assert!(value.get("argv").is_none());
        assert!(value.get("model").is_none());
        assert!(value.get("allow_custom_model").is_none());
    }

    #[test]
    fn status_and_size_helpers_follow_wire_values() {
        assert_eq!(
            AgentTuiStatus::parse("running"),
            Ok(AgentTuiStatus::Running)
        );
        assert_eq!(AgentTuiStatus::Running.as_str(), "running");
        assert_eq!(
            AgentTuiSize::default(),
            AgentTuiSize {
                rows: DEFAULT_AGENT_TUI_ROWS,
                cols: DEFAULT_AGENT_TUI_COLS,
            }
        );
    }
}
