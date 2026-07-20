//! CLI surface over the agent's own session store.
//!
//! These ids belong to the agent rather than to harness, so every subcommand
//! takes the managed agent first and an agent-reported session id second.

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::session::transport::support::{daemon_client, print_json};

#[derive(Debug, Clone, Args)]
pub struct AcpSessionsArgs {
    /// Managed ACP agent ID.
    pub acp_id: String,
    /// Only list sessions the agent associates with this working directory.
    #[arg(long)]
    pub cwd: Option<String>,
    /// Opaque pagination cursor from a previous listing.
    #[arg(long)]
    pub cursor: Option<String>,
}

impl Execute for AcpSessionsArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response = daemon_client()?.list_acp_agent_sessions(
            &self.acp_id,
            self.cwd.as_deref(),
            self.cursor.as_deref(),
        )?;
        print_json(&response)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct AcpCloseSessionArgs {
    /// Managed ACP agent ID.
    pub acp_id: String,
    /// Agent-owned session ID, as reported by `sessions`.
    pub agent_session_id: String,
}

impl Execute for AcpCloseSessionArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response =
            daemon_client()?.close_acp_agent_session(&self.acp_id, &self.agent_session_id)?;
        print_json(&response)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct AcpDeleteSessionArgs {
    /// Managed ACP agent ID.
    pub acp_id: String,
    /// Agent-owned session ID, as reported by `sessions`.
    pub agent_session_id: String,
}

impl Execute for AcpDeleteSessionArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response =
            daemon_client()?.delete_acp_agent_session(&self.acp_id, &self.agent_session_id)?;
        print_json(&response)?;
        Ok(0)
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser;

    use super::*;

    #[derive(Debug, Parser)]
    struct SessionsParse {
        #[command(flatten)]
        args: AcpSessionsArgs,
    }

    #[derive(Debug, Parser)]
    struct CloseParse {
        #[command(flatten)]
        args: AcpCloseSessionArgs,
    }

    #[derive(Debug, Parser)]
    struct DeleteParse {
        #[command(flatten)]
        args: AcpDeleteSessionArgs,
    }

    #[test]
    fn sessions_cli_parses_optional_cwd_and_cursor() {
        let parsed = SessionsParse::try_parse_from([
            "sessions",
            "agent-acp-1",
            "--cwd",
            "/work",
            "--cursor",
            "page-2",
        ])
        .expect("parse");
        assert_eq!(parsed.args.acp_id, "agent-acp-1");
        assert_eq!(parsed.args.cwd.as_deref(), Some("/work"));
        assert_eq!(parsed.args.cursor.as_deref(), Some("page-2"));
    }

    #[test]
    fn sessions_cli_defaults_to_unfiltered_first_page() {
        let parsed = SessionsParse::try_parse_from(["sessions", "agent-acp-1"]).expect("parse");
        assert_eq!(parsed.args.cwd, None);
        assert_eq!(parsed.args.cursor, None);
    }

    #[test]
    fn close_and_delete_cli_take_agent_then_session() {
        let closed = CloseParse::try_parse_from(["close-session", "agent-acp-1", "acp-session-7"])
            .expect("parse");
        assert_eq!(closed.args.acp_id, "agent-acp-1");
        assert_eq!(closed.args.agent_session_id, "acp-session-7");

        let deleted =
            DeleteParse::try_parse_from(["delete-session", "agent-acp-1", "acp-session-9"])
                .expect("parse");
        assert_eq!(deleted.args.acp_id, "agent-acp-1");
        assert_eq!(deleted.args.agent_session_id, "acp-session-9");
    }

    #[test]
    fn close_session_cli_requires_both_ids() {
        assert!(CloseParse::try_parse_from(["close-session", "agent-acp-1"]).is_err());
    }
}
