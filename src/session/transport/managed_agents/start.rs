use std::collections::BTreeMap;

use clap::{Args, Subcommand};

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::agent_acp::{AcpAgentStartRequest, AcpEndpoint};
use crate::daemon::agent_tui::AgentTuiStartRequest;
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest};
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::session::types::SessionRole;

use crate::session::transport::support::{
    agent_to_str, capability_args, daemon_client, print_json, resolve_project_dir,
};

use super::acp_sessions::{AcpCloseSessionArgs, AcpDeleteSessionArgs, AcpSessionsArgs};

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
#[expect(
    clippy::large_enum_variant,
    reason = "Clap command variants keep their derived subcommand payloads by value"
)]
pub enum SessionAgentsCommand {
    /// Start a managed terminal session or Codex thread.
    Start {
        #[command(subcommand)]
        command: SessionAgentStartCommand,
    },
    /// Attach to a live managed terminal agent.
    Attach(super::attach::ManagedAgentAttachArgs),
    /// List managed agents for a session.
    List(super::ManagedAgentListArgs),
    /// Show one managed agent snapshot.
    Show(super::ManagedAgentShowArgs),
    /// Send keyboard-like input to a managed terminal agent.
    Input(super::terminal::ManagedTerminalInputArgs),
    /// Resize a managed terminal agent viewport.
    Resize(super::terminal::ManagedTerminalResizeArgs),
    /// Stop a managed terminal agent session.
    Stop(super::terminal::ManagedTerminalStopArgs),
    /// Send additional context to a managed Codex thread.
    Steer(super::codex::CodexAgentSteerArgs),
    /// Interrupt a managed Codex thread.
    Interrupt(super::codex::CodexAgentInterruptArgs),
    /// Resolve a managed Codex approval request.
    Approve(super::codex::CodexAgentApprovalArgs),
    /// ACP agent lifecycle and observability commands.
    Acp {
        #[command(subcommand)]
        command: AcpAgentCommand,
    },
}

impl Execute for SessionAgentsCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Start { command } => command.execute(context),
            Self::Attach(args) => args.execute(context),
            Self::List(args) => args.execute(context),
            Self::Show(args) => args.execute(context),
            Self::Input(args) => args.execute(context),
            Self::Resize(args) => args.execute(context),
            Self::Stop(args) => args.execute(context),
            Self::Steer(args) => args.execute(context),
            Self::Interrupt(args) => args.execute(context),
            Self::Approve(args) => args.execute(context),
            Self::Acp { command } => command.execute(context),
        }
    }
}

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum SessionAgentStartCommand {
    /// Start an interactive terminal-backed agent session.
    Terminal(TerminalAgentStartArgs),
    /// Start a structured Codex thread.
    Codex(CodexAgentStartArgs),
    /// Start an ACP-backed agent session.
    Acp(AcpAgentStartArgs),
}

impl Execute for SessionAgentStartCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Terminal(args) => args.execute(context),
            Self::Codex(args) => args.execute(context),
            Self::Acp(args) => args.execute(context),
        }
    }
}

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum AcpAgentCommand {
    /// Inspect live ACP sessions.
    Inspect(AcpInspectArgs),
    /// Ask an ACP agent to log out (requires the auth.logout capability).
    Logout(AcpLogoutArgs),
    /// List the sessions an ACP agent itself knows about.
    Sessions(AcpSessionsArgs),
    /// Ask an ACP agent to close one of its sessions.
    CloseSession(AcpCloseSessionArgs),
    /// Ask an ACP agent to delete one of its sessions.
    DeleteSession(AcpDeleteSessionArgs),
}

impl Execute for AcpAgentCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Inspect(args) => args.execute(context),
            Self::Logout(args) => args.execute(context),
            Self::Sessions(args) => args.execute(context),
            Self::CloseSession(args) => args.execute(context),
            Self::DeleteSession(args) => args.execute(context),
        }
    }
}

#[derive(Debug, Clone, Args)]
pub struct AcpAgentStartArgs {
    /// Session ID.
    #[arg(long)]
    pub session_id: String,
    /// ACP descriptor ID to launch.
    #[arg(long)]
    pub agent: String,
    /// Role to register the ACP agent as.
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
    /// Persona identifier to attach to the agent registration.
    #[arg(long)]
    pub persona: Option<String>,
    /// Model identifier to launch when the ACP runtime supports overrides.
    #[arg(long)]
    pub model: Option<String>,
    /// Reasoning effort level when the ACP runtime supports overrides.
    #[arg(long)]
    pub effort: Option<String>,
    /// Allow model identifiers outside the advertised catalog.
    #[arg(long)]
    pub allow_custom_model: bool,
    /// Record ACP permission decisions without granting permission requests.
    #[arg(long)]
    pub record_permissions: bool,
    /// Extra root the agent may work in, beyond the project directory. May be
    /// repeated. Ignored by agents that do not advertise `additionalDirectories`.
    #[arg(long = "additional-directory")]
    pub additional_directories: Vec<String>,
    /// Pick up this agent session instead of opening a new one, by resume or
    /// load depending on what the agent supports. Overrides the session the
    /// daemon would have picked up on its own.
    #[arg(long = "resume-session", conflicts_with = "no_resume")]
    pub resume_session_id: Option<String>,
    /// Always open a new session, even when a previous one could be resumed or
    /// loaded.
    #[arg(long = "no-resume")]
    pub no_resume: bool,
    /// Connect to a remote ACP endpoint instead of spawning the descriptor's
    /// command. `ws`/`wss` uses WebSocket, `http`/`https` uses SSE with POST.
    /// The descriptor still names the agent; its launch command is not run.
    #[arg(long)]
    pub endpoint: Option<String>,
    /// Header for the remote connection as `Name=ENV_VAR`. The daemon reads the
    /// value from that environment variable at connect time, so the secret
    /// never rides the request. Only http/https endpoints accept headers; ws/wss
    /// cannot carry them. Repeatable; requires `--endpoint`.
    #[arg(long = "header-env", requires = "endpoint")]
    pub header_env: Vec<String>,
}

impl Execute for AcpAgentStartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let endpoint = self
            .endpoint
            .as_deref()
            .map(|url| build_endpoint(url, &self.header_env))
            .transpose()?;
        let request = AcpAgentStartRequest {
            agent: self.agent.clone(),
            role: self.role,
            fallback_role: self.fallback_role,
            capabilities: capability_args(&self.capabilities),
            name: self.name.clone(),
            prompt: self.prompt.clone(),
            project_dir: self
                .project_dir
                .as_deref()
                .map(|hint| resolve_project_dir(Some(hint))),
            persona: self.persona.clone(),
            task_id: None,
            board_item_id: None,
            workflow_execution_id: None,
            model: self.model.clone(),
            effort: self.effort.clone(),
            allow_custom_model: self.allow_custom_model,
            record_permissions: self.record_permissions,
            // Too structured for a flag; set these over the HTTP start route.
            mcp_servers: Vec::new(),
            additional_directories: self.additional_directories.clone(),
            resume_session_id: self.resume_session_id.clone(),
            resume_disabled: self.no_resume,
            endpoint,
        };
        let snapshot = daemon_client()?.start_acp_managed_agent(&self.session_id, &request)?;
        print_json(&snapshot)?;
        Ok(0)
    }
}

/// Parse `--header-env NAME=ENV_VAR` pairs into an endpoint. The map records the
/// environment variable name, not its value: the daemon resolves it at connect
/// time so a token never crosses the start request.
fn build_endpoint(url: &str, header_env: &[String]) -> Result<AcpEndpoint, CliError> {
    let mut endpoint_headers: BTreeMap<String, String> = BTreeMap::new();
    for entry in header_env {
        let (name, var) = entry
            .split_once('=')
            .filter(|(name, var)| !name.is_empty() && !var.is_empty())
            .ok_or_else(|| {
                CliErrorKind::workflow_parse(format!("--header-env '{entry}' must be NAME=ENV_VAR"))
            })?;
        // HTTP header names are case-insensitive, so reject a repeat under any
        // casing rather than let the later one silently win.
        if endpoint_headers
            .keys()
            .any(|existing| existing.eq_ignore_ascii_case(name))
        {
            return Err(CliErrorKind::workflow_parse(format!(
                "--header-env sets header '{name}' more than once"
            ))
            .into());
        }
        endpoint_headers.insert(name.to_string(), var.to_string());
    }
    Ok(AcpEndpoint {
        url: url.to_string(),
        headers_env: endpoint_headers,
    })
}

#[derive(Debug, Clone, Args)]
pub struct AcpInspectArgs {
    /// Optional session ID filter. Omit to inspect every live ACP session.
    #[arg(long)]
    pub session_id: Option<String>,
    /// Emit the raw daemon snapshot as JSON instead of the doctor view.
    #[arg(long)]
    pub json: bool,
}

impl Execute for AcpInspectArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response = daemon_client()?.inspect_acp_managed_agents(self.session_id.as_deref())?;
        if self.json {
            print_json(&response)?;
        } else {
            println!("{}", super::inspect::render_inspect(&response));
        }
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct AcpLogoutArgs {
    /// Managed ACP agent ID.
    pub acp_id: String,
}

impl Execute for AcpLogoutArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response = daemon_client()?.logout_acp_managed_agent(&self.acp_id)?;
        print_json(&response)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TerminalAgentStartArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent runtime to launch.
    #[arg(long, value_enum)]
    pub runtime: HookAgent,
    /// Role to register the managed terminal agent as.
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
    /// Model identifier validated against the runtime's catalog. Defaults to
    /// the runtime default when omitted.
    #[arg(long)]
    pub model: Option<String>,
    /// Reasoning/thinking effort level. Must be a level supported by the
    /// selected model; runtimes whose CLI does not accept the flag ignore it
    /// with a warning.
    #[arg(long)]
    pub effort: Option<String>,
    /// Accept `--model` as-is without validating against the runtime's model
    /// catalog. Used for provider previews or self-hosted identifiers that
    /// Harness does not pre-register.
    #[arg(long)]
    pub allow_custom_model: bool,
}

impl Execute for TerminalAgentStartArgs {
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
            task_id: None,
            board_item_id: None,
            workflow_execution_id: None,
            model: self.model.clone(),
            effort: self.effort.clone(),
            allow_custom_model: self.allow_custom_model,
        };
        let snapshot = daemon_client()?.start_terminal_managed_agent(&self.session_id, &request)?;
        print_json(&snapshot)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct CodexAgentStartArgs {
    /// Session ID.
    pub session_id: String,
    /// Initial prompt to send to Codex.
    #[arg(long)]
    pub prompt: String,
    /// Codex execution mode.
    #[arg(long, value_enum, default_value = "report")]
    pub mode: CodexRunMode,
    /// Role to register the Codex app-server agent as.
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
    /// Persona identifier to attach to the agent registration.
    #[arg(long)]
    pub persona: Option<String>,
    /// Resume an existing Codex thread instead of starting a new one.
    #[arg(long)]
    pub resume_thread_id: Option<String>,
    /// Model identifier validated against the codex catalog. Defaults to the
    /// codex runtime default when omitted.
    #[arg(long)]
    pub model: Option<String>,
    /// Reasoning effort level forwarded to the codex app-server. Must match a
    /// value supported by the selected model; ignored when the model does not
    /// support reasoning.
    #[arg(long)]
    pub effort: Option<String>,
    /// Accept `--model` as-is without validating against the codex catalog.
    #[arg(long)]
    pub allow_custom_model: bool,
}

impl Execute for CodexAgentStartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = CodexRunRequest {
            actor: None,
            prompt: self.prompt.clone(),
            mode: self.mode,
            role: self.role,
            fallback_role: self.fallback_role,
            capabilities: capability_args(&self.capabilities),
            name: self.name.clone(),
            persona: self.persona.clone(),
            resume_thread_id: self.resume_thread_id.clone(),
            task_id: None,
            board_item_id: None,
            workflow_execution_id: None,
            model: self.model.clone(),
            effort: self.effort.clone(),
            allow_custom_model: self.allow_custom_model,
        };
        let snapshot = daemon_client()?.start_codex_managed_agent(&self.session_id, &request)?;
        print_json(&snapshot)?;
        Ok(0)
    }
}

#[cfg(test)]
mod tests;
