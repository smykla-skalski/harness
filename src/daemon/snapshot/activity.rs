use super::super::index::{self, DiscoveredProject};
use super::super::protocol::AgentToolActivitySummary;
use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::errors::CliError;
use crate::session::types::SessionState;

/// Load agent activity summaries from transcript files.
///
/// # Errors
/// Returns [`CliError`] on filesystem read failures.
pub fn load_agent_activity_for(
    project: &DiscoveredProject,
    state: &SessionState,
) -> Result<Vec<AgentToolActivitySummary>, CliError> {
    let mut summaries = Vec::new();
    for (agent_id, agent) in &state.agents {
        let session_key = agent
            .agent_session_id
            .as_deref()
            .unwrap_or(&state.session_id);
        let events =
            index::load_conversation_events(project, &agent.runtime, session_key, agent_id)?;
        summaries.push(agent_activity_summary_from_events(
            agent_id,
            &agent.runtime,
            agent.last_activity_at.as_deref(),
            &events,
        ));
    }
    summaries.sort_by(|left, right| left.agent_id.cmp(&right.agent_id));
    Ok(summaries)
}

pub(crate) fn agent_activity_summary_from_events(
    agent_id: &str,
    runtime: &str,
    fallback_last_activity: Option<&str>,
    events: &[ConversationEvent],
) -> AgentToolActivitySummary {
    let mut summary = AgentToolActivitySummary {
        agent_id: agent_id.to_string(),
        runtime: runtime.to_string(),
        tool_invocation_count: 0,
        tool_result_count: 0,
        tool_error_count: 0,
        latest_tool_name: None,
        latest_event_at: fallback_last_activity.map(ToString::to_string),
        recent_tools: Vec::new(),
    };

    for event in events {
        match &event.kind {
            ConversationEventKind::ToolInvocation { tool_name, .. } => {
                summary.tool_invocation_count += 1;
                record_tool_event(&mut summary, tool_name.as_str(), event.timestamp.as_deref());
            }
            ConversationEventKind::ToolResult {
                tool_name,
                is_error,
                ..
            } => {
                summary.tool_result_count += 1;
                if *is_error {
                    summary.tool_error_count += 1;
                }
                record_tool_event(&mut summary, tool_name.as_str(), event.timestamp.as_deref());
            }
            ConversationEventKind::Error { .. } => {
                summary.tool_error_count += 1;
                if let Some(timestamp) = event.timestamp.as_deref() {
                    summary.latest_event_at = Some(timestamp.to_owned());
                }
            }
            _ => {}
        }
    }

    summary
}

fn record_tool_event(
    summary: &mut AgentToolActivitySummary,
    tool_name: &str,
    timestamp: Option<&str>,
) {
    if let Some(timestamp) = timestamp {
        summary.latest_event_at = Some(timestamp.to_string());
    }
    if tool_name.is_empty() || tool_name == "unknown" {
        return;
    }

    summary.latest_tool_name = Some(tool_name.to_string());
    summary
        .recent_tools
        .retain(|existing| existing != tool_name);
    summary.recent_tools.insert(0, tool_name.to_string());
    if summary.recent_tools.len() > 5 {
        summary.recent_tools.truncate(5);
    }
}
