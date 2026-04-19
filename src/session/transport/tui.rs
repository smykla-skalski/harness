use clap::{Args, ValueEnum};

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::agent_tui::{
    AgentTuiInput, AgentTuiInputRequest, AgentTuiKey, AgentTuiResizeRequest, AgentTuiStartRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::session::types::SessionRole;

use super::support::{
    agent_to_str, capability_args, daemon_client, print_json, resolve_project_dir,
};

#[derive(Debug, Clone, Args)]
pub struct TuiStartArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent runtime to launch.
    #[arg(long, value_enum)]
    pub runtime: HookAgent,
    /// Role to register the managed TUI agent as.
    #[arg(long, value_enum, default_value = "worker")]
    pub role: SessionRole,
    /// Fallback role to use when joining as leader and a leader already exists.
    #[arg(long, value_enum)]
    pub fallback_role: Option<SessionRole>,
    /// Capability tag. May be repeated or comma-separated.
    #[arg(long = "capability")]
    pub capabilities: Vec<String>,
    /// Human-readable agent display name.
    #[arg(long)]
    pub name: Option<String>,
    /// Optional first prompt to submit after launch.
    #[arg(long)]
    pub prompt: Option<String>,
    /// Project directory. Defaults to the daemon's session project.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    /// Override argv, one argument per --arg.
    #[arg(long = "arg", allow_hyphen_values = true)]
    pub argv: Vec<String>,
    /// Initial PTY rows.
    #[arg(long, default_value_t = 30)]
    pub rows: u16,
    /// Initial PTY columns.
    #[arg(long, default_value_t = 120)]
    pub cols: u16,
    /// Persona identifier to attach to the agent registration.
    #[arg(long)]
    pub persona: Option<String>,
}

impl Execute for TuiStartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = AgentTuiStartRequest {
            runtime: agent_to_str(self.runtime).to_string(),
            role: self.role,
            fallback_role: self.fallback_role,
            capabilities: capability_args(&self.capabilities),
            name: self.name.clone(),
            prompt: self.prompt.clone(),
            project_dir: self
                .project_dir
                .as_deref()
                .map(|hint| resolve_project_dir(Some(hint))),
            argv: self.argv.clone(),
            rows: self.rows,
            cols: self.cols,
            persona: self.persona.clone(),
        };
        let snapshot = daemon_client()?.start_agent_tui(&self.session_id, &request)?;
        print_json(&snapshot)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TuiListArgs {
    /// Session ID.
    pub session_id: String,
}

impl Execute for TuiListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response = daemon_client()?.list_agent_tuis(&self.session_id)?;
        print_json(&response)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TuiShowArgs {
    /// Managed TUI ID.
    pub tui_id: String,
}

impl Execute for TuiShowArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let snapshot = daemon_client()?.get_agent_tui(&self.tui_id)?;
        print_json(&snapshot)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum TuiKeyArg {
    Enter,
    Escape,
    Tab,
    Backspace,
    ArrowUp,
    ArrowDown,
    ArrowRight,
    ArrowLeft,
}

impl From<TuiKeyArg> for AgentTuiKey {
    fn from(value: TuiKeyArg) -> Self {
        match value {
            TuiKeyArg::Enter => Self::Enter,
            TuiKeyArg::Escape => Self::Escape,
            TuiKeyArg::Tab => Self::Tab,
            TuiKeyArg::Backspace => Self::Backspace,
            TuiKeyArg::ArrowUp => Self::ArrowUp,
            TuiKeyArg::ArrowDown => Self::ArrowDown,
            TuiKeyArg::ArrowRight => Self::ArrowRight,
            TuiKeyArg::ArrowLeft => Self::ArrowLeft,
        }
    }
}

#[derive(Debug, Clone, Args)]
pub struct TuiInputArgs {
    /// Managed TUI ID.
    pub tui_id: String,
    /// Send plain text bytes.
    #[arg(long)]
    pub text: Option<String>,
    /// Send bracketed paste text.
    #[arg(long)]
    pub paste: Option<String>,
    /// Send a named key.
    #[arg(long, value_enum)]
    pub key: Option<TuiKeyArg>,
    /// Send a Ctrl+key combination.
    #[arg(long)]
    pub control: Option<char>,
    /// Send raw bytes encoded as base64.
    #[arg(long)]
    pub raw_base64: Option<String>,
}

impl Execute for TuiInputArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let snapshot = daemon_client()?.send_agent_tui_input(
            &self.tui_id,
            &AgentTuiInputRequest {
                input: self.input()?,
            },
        )?;
        print_json(&snapshot)?;
        Ok(0)
    }
}

impl TuiInputArgs {
    fn input(&self) -> Result<AgentTuiInput, CliError> {
        let selected = usize::from(self.text.is_some())
            + usize::from(self.paste.is_some())
            + usize::from(self.key.is_some())
            + usize::from(self.control.is_some())
            + usize::from(self.raw_base64.is_some());
        if selected != 1 {
            return Err(CliErrorKind::workflow_parse(
                "provide exactly one of --text, --paste, --key, --control, or --raw-base64",
            )
            .into());
        }
        if let Some(text) = &self.text {
            return Ok(AgentTuiInput::Text { text: text.clone() });
        }
        if let Some(text) = &self.paste {
            return Ok(AgentTuiInput::Paste { text: text.clone() });
        }
        if let Some(key) = self.key {
            return Ok(AgentTuiInput::Key { key: key.into() });
        }
        if let Some(key) = self.control {
            return Ok(AgentTuiInput::Control { key });
        }
        Ok(AgentTuiInput::RawBytesBase64 {
            data: self.raw_base64.clone().unwrap_or_default(),
        })
    }
}

#[derive(Debug, Clone, Args)]
pub struct TuiResizeArgs {
    /// Managed TUI ID.
    pub tui_id: String,
    /// New PTY rows.
    #[arg(long)]
    pub rows: u16,
    /// New PTY columns.
    #[arg(long)]
    pub cols: u16,
}

impl Execute for TuiResizeArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let snapshot = daemon_client()?.resize_agent_tui(
            &self.tui_id,
            &AgentTuiResizeRequest {
                rows: self.rows,
                cols: self.cols,
            },
        )?;
        print_json(&snapshot)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TuiStopArgs {
    /// Managed TUI ID.
    pub tui_id: String,
}

impl Execute for TuiStopArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let snapshot = daemon_client()?.stop_agent_tui(&self.tui_id)?;
        print_json(&snapshot)?;
        Ok(0)
    }
}
