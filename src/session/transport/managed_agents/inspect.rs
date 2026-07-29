//! Human-readable "doctor" view for `harness session agents ... acp inspect`:
//! per-agent negotiated protocol version, agentInfo, and informational
//! freshness notes. The `--json` flag emits the raw daemon snapshot instead.

use harness_protocol::managed_agents::acp::{
    AcpAgentHandshake, AcpAgentInspectResponse, AcpAgentInspectSnapshot,
};

/// The protocol version harness offers in `session/initialize`. Mirrors the
/// `InitializeRequest::new(ProtocolVersion::V1)` the daemon sends; an agent that
/// negotiates below this speaks an older, pre-release protocol.
const HARNESS_PROTOCOL_VERSION: u16 = 1;

/// Render the live ACP agents as a doctor-style report, or a single line when
/// the daemon has no ACP state to report.
pub(super) fn render_inspect(response: &AcpAgentInspectResponse) -> String {
    if !response.available {
        return format!(
            "acp inspect unavailable: {}",
            response
                .issue_message
                .as_deref()
                .unwrap_or("daemon did not report ACP state")
        );
    }
    if response.agents.is_empty() {
        return "no live ACP agents".to_string();
    }
    response
        .agents
        .iter()
        .flat_map(agent_lines)
        .collect::<Vec<_>>()
        .join("\n")
}

fn agent_lines(agent: &AcpAgentInspectSnapshot) -> Vec<String> {
    let mut lines = vec![
        format!("{} [{}]", agent.display_name, agent.acp_id),
        format!("  session: {}", agent.session_id),
    ];
    match &agent.handshake {
        Some(handshake) => lines.extend(handshake_lines(handshake)),
        None => lines.push("  handshake: pending (initialize not yet recorded)".to_string()),
    }
    lines
}

fn handshake_lines(handshake: &AcpAgentHandshake) -> Vec<String> {
    let mut lines = vec![format!("  protocol: v{}", handshake.protocol_version)];
    lines.push(match (&handshake.agent_name, &handshake.agent_version) {
        (Some(name), Some(version)) => format!("  agent: {name} {version}"),
        (Some(name), None) => format!("  agent: {name} (version unreported)"),
        _ => "  agent: unreported".to_string(),
    });
    if let Some(title) = &handshake.agent_title {
        lines.push(format!("  title: {title}"));
    }
    for note in freshness_notes(handshake) {
        lines.push(format!("  freshness: {note}"));
    }
    lines
}

/// Informational, non-gating notes about how current an agent looks. Empty when
/// the agent reports agentInfo and negotiated the protocol version harness offers.
fn freshness_notes(handshake: &AcpAgentHandshake) -> Vec<String> {
    let mut notes = Vec::new();
    if handshake.protocol_version < HARNESS_PROTOCOL_VERSION {
        notes.push(format!(
            "negotiated protocol v{} is below harness's v{HARNESS_PROTOCOL_VERSION}; the agent speaks an older protocol",
            handshake.protocol_version
        ));
    }
    if handshake.agent_name.is_none() || handshake.agent_version.is_none() {
        notes.push(
            "agent did not report agentInfo (name/version), so its freshness cannot be verified"
                .to_string(),
        );
    }
    notes
}

#[cfg(test)]
mod tests {
    use super::{freshness_notes, render_inspect};
    use harness_protocol::managed_agents::acp::{
        AcpAgentHandshake, AcpAgentInspectResponse, AcpAgentInspectSnapshot,
    };

    fn handshake(protocol: u16, name: Option<&str>, version: Option<&str>) -> AcpAgentHandshake {
        AcpAgentHandshake {
            protocol_version: protocol,
            agent_name: name.map(str::to_string),
            agent_version: version.map(str::to_string),
            ..AcpAgentHandshake::default()
        }
    }

    fn snapshot(handshake: Option<AcpAgentHandshake>) -> AcpAgentInspectSnapshot {
        AcpAgentInspectSnapshot {
            acp_id: "acp-1".to_string(),
            session_id: "session-1".to_string(),
            agent_id: "agent-1".to_string(),
            display_name: "Codex".to_string(),
            pid: 1234,
            pgid: 1234,
            process_key: "codex-acp".to_string(),
            uptime_ms: 1000,
            last_update_at: "2026-07-20T00:00:00Z".to_string(),
            last_client_call_at: None,
            watchdog_state: "healthy".to_string(),
            permission_mode: "gateway".to_string(),
            permission_log_path: None,
            pending_permissions: 0,
            permission_queue_depth: 0,
            terminal_count: 0,
            prompt_deadline_remaining_ms: 0,
            handshake,
            session_state: None,
        }
    }

    fn response(agents: Vec<AcpAgentInspectSnapshot>, available: bool) -> AcpAgentInspectResponse {
        AcpAgentInspectResponse {
            agents,
            daemon_perceived_now: None,
            available,
            issue_message: if available {
                None
            } else {
                Some("daemon down".to_string())
            },
        }
    }

    #[test]
    fn current_agent_has_no_freshness_notes() {
        let notes = freshness_notes(&handshake(1, Some("codex-acp"), Some("0.16.0")));
        assert!(
            notes.is_empty(),
            "current agent should have no notes: {notes:?}"
        );
    }

    #[test]
    fn pre_release_protocol_is_flagged() {
        let notes = freshness_notes(&handshake(0, Some("old"), Some("0.1.0")));
        assert!(
            notes.iter().any(|note| note.contains("v0")),
            "notes: {notes:?}"
        );
    }

    #[test]
    fn missing_agent_info_is_flagged() {
        let notes = freshness_notes(&handshake(1, None, None));
        assert!(
            notes.iter().any(|note| note.contains("agentInfo")),
            "notes: {notes:?}"
        );
    }

    #[test]
    fn missing_version_alone_is_flagged() {
        let notes = freshness_notes(&handshake(1, Some("agent"), None));
        assert!(
            notes.iter().any(|note| note.contains("agentInfo")),
            "notes: {notes:?}"
        );
    }

    #[test]
    fn render_reports_unavailable_daemon() {
        let text = render_inspect(&response(vec![], false));
        assert!(text.contains("unavailable"), "text: {text}");
        assert!(text.contains("daemon down"), "text: {text}");
    }

    #[test]
    fn render_reports_no_agents() {
        let text = render_inspect(&response(vec![], true));
        assert!(text.contains("no live ACP agents"), "text: {text}");
    }

    #[test]
    fn render_shows_protocol_and_agent_info() {
        let text = render_inspect(&response(
            vec![snapshot(Some(handshake(
                1,
                Some("codex-acp"),
                Some("0.16.0"),
            )))],
            true,
        ));
        assert!(text.contains("protocol: v1"), "text: {text}");
        assert!(text.contains("codex-acp 0.16.0"), "text: {text}");
    }

    #[test]
    fn render_flags_pending_handshake() {
        let text = render_inspect(&response(vec![snapshot(None)], true));
        assert!(text.contains("pending"), "text: {text}");
    }
}
