use clap::{Args, ValueEnum};

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::agent_tui::{
    AgentTuiInput, AgentTuiInputRequest, AgentTuiKey, AgentTuiResizeRequest,
};
use crate::errors::{CliError, CliErrorKind};

use crate::session::transport::support::{daemon_client, print_json};

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
pub struct ManagedTerminalInputArgs {
    /// Managed terminal agent ID.
    pub agent_id: String,
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

impl Execute for ManagedTerminalInputArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let snapshot = daemon_client()?.send_managed_terminal_input(
            &self.agent_id,
            &AgentTuiInputRequest {
                input: self.input()?,
            },
        )?;
        print_json(&snapshot)?;
        Ok(0)
    }
}

impl ManagedTerminalInputArgs {
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
pub struct ManagedTerminalResizeArgs {
    /// Managed terminal agent ID.
    pub agent_id: String,
    /// New PTY rows.
    #[arg(long)]
    pub rows: u16,
    /// New PTY columns.
    #[arg(long)]
    pub cols: u16,
}

impl Execute for ManagedTerminalResizeArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let snapshot = daemon_client()?.resize_managed_terminal(
            &self.agent_id,
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
pub struct ManagedTerminalStopArgs {
    /// Managed terminal agent ID.
    pub agent_id: String,
}

impl Execute for ManagedTerminalStopArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let snapshot = daemon_client()?.stop_managed_terminal(&self.agent_id)?;
        print_json(&snapshot)?;
        Ok(0)
    }
}
