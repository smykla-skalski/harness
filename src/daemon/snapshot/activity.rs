use serde_json::Value;

use super::super::index::{self, DiscoveredProject};
use super::super::protocol::{AgentPendingUserPrompt, AgentToolActivitySummary};
use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::errors::CliError;
use crate::hooks::protocol::payloads::AskUserQuestionPrompt;
use crate::session::types::SessionState;

#[derive(Debug, Clone)]
struct PendingUserPromptInvocation {
    invocation_id: Option<String>,
    prompt: AgentPendingUserPrompt,
}

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
        let events = index::load_conversation_events(
            project,
            agent.runtime.runtime_name(),
            session_key,
            agent_id,
        )?;
        summaries.push(agent_activity_summary_from_events(
            agent_id,
            agent.runtime.runtime_name(),
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
        pending_user_prompt: None,
    };
    let mut pending_user_prompts = Vec::new();

    for event in events {
        match &event.kind {
            ConversationEventKind::ToolInvocation {
                tool_name,
                input,
                invocation_id,
                ..
            } => {
                summary.tool_invocation_count += 1;
                record_tool_event(&mut summary, tool_name.as_str(), event.timestamp.as_deref());
                record_pending_user_prompt(
                    &mut pending_user_prompts,
                    tool_name,
                    invocation_id.as_deref(),
                    input,
                    event.timestamp.as_deref(),
                );
            }
            ConversationEventKind::ToolResult {
                tool_name,
                is_error,
                invocation_id,
                ..
            } => {
                summary.tool_result_count += 1;
                if *is_error {
                    summary.tool_error_count += 1;
                }
                record_tool_event(&mut summary, tool_name.as_str(), event.timestamp.as_deref());
                clear_pending_user_prompt(
                    &mut pending_user_prompts,
                    tool_name,
                    invocation_id.as_deref(),
                );
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

    summary.pending_user_prompt = pending_user_prompts.pop().map(|pending| pending.prompt);
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

fn record_pending_user_prompt(
    pending_user_prompts: &mut Vec<PendingUserPromptInvocation>,
    tool_name: &str,
    invocation_id: Option<&str>,
    input: &Value,
    timestamp: Option<&str>,
) {
    let Some(prompt) = pending_user_prompt_from(tool_name, input, timestamp) else {
        return;
    };

    if let Some(invocation_id) = invocation_id {
        pending_user_prompts
            .retain(|existing| existing.invocation_id.as_deref() != Some(invocation_id));
    }

    pending_user_prompts.push(PendingUserPromptInvocation {
        invocation_id: invocation_id.map(ToOwned::to_owned),
        prompt,
    });
}

fn clear_pending_user_prompt(
    pending_user_prompts: &mut Vec<PendingUserPromptInvocation>,
    tool_name: &str,
    invocation_id: Option<&str>,
) {
    if !is_user_prompt_tool(tool_name) {
        return;
    }

    if let Some(invocation_id) = invocation_id {
        pending_user_prompts
            .retain(|existing| existing.invocation_id.as_deref() != Some(invocation_id));
        return;
    }

    if let Some(index) = pending_user_prompts
        .iter()
        .rposition(|existing| existing.invocation_id.is_none())
    {
        pending_user_prompts.remove(index);
    }
}

fn pending_user_prompt_from(
    tool_name: &str,
    input: &Value,
    timestamp: Option<&str>,
) -> Option<AgentPendingUserPrompt> {
    if !is_user_prompt_tool(tool_name) {
        return None;
    }

    let questions = extract_pending_user_prompt_questions(input)?;
    let message = questions
        .first()
        .map(AskUserQuestionPrompt::question_head)
        .map(ToOwned::to_owned);

    Some(AgentPendingUserPrompt {
        tool_name: tool_name.to_owned(),
        waiting_since: timestamp.map(ToOwned::to_owned),
        questions,
        message,
    })
}

fn extract_pending_user_prompt_questions(input: &Value) -> Option<Vec<AskUserQuestionPrompt>> {
    if let Some(questions) = extract_canonical_prompt_questions(input) {
        return Some(questions);
    }

    let question = extract_flat_prompt_question(input)?;
    Some(vec![AskUserQuestionPrompt {
        question,
        header: None,
        options: Vec::new(),
        multi_select: false,
    }])
}

fn extract_canonical_prompt_questions(input: &Value) -> Option<Vec<AskUserQuestionPrompt>> {
    let Value::Object(object) = input else {
        return None;
    };
    let questions = object.get("questions")?.clone();
    let questions = serde_json::from_value::<Vec<AskUserQuestionPrompt>>(questions).ok()?;
    (!questions.is_empty()).then_some(questions)
}

fn extract_flat_prompt_question(input: &Value) -> Option<String> {
    match input {
        Value::String(message) => trimmed_non_empty(message),
        Value::Object(object) => ["message", "prompt", "question"]
            .iter()
            .find_map(|key| object.get(*key).and_then(Value::as_str))
            .and_then(trimmed_non_empty),
        _ => None,
    }
}

fn trimmed_non_empty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

fn is_user_prompt_tool(tool_name: &str) -> bool {
    let normalized: String = tool_name
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .collect();
    matches!(
        normalized.to_ascii_lowercase().as_str(),
        "askuser" | "askuserquestion"
    )
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::agent_activity_summary_from_events;
    use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};

    #[test]
    fn unresolved_ask_user_invocation_surfaces_pending_prompt() {
        let summary = agent_activity_summary_from_events(
            "agent-alpha",
            "claude",
            None,
            &[tool_invocation(
                1,
                "ask-1",
                "AskUserQuestion",
                json!({
                    "questions": [{
                        "question": "Approve the file write?",
                        "header": "Approval",
                        "options": [
                            { "label": "Allow", "description": "Proceed with the write" },
                            { "label": "Deny", "description": "Stop before writing" }
                        ],
                        "multi_select": false
                    }]
                }),
            )],
        );

        let pending_prompt = summary
            .pending_user_prompt
            .expect("expected unresolved ask_user prompt");
        assert_eq!(pending_prompt.tool_name, "AskUserQuestion");
        assert_eq!(
            pending_prompt.waiting_since.as_deref(),
            Some("2026-04-28T08:00:01Z")
        );
        assert_eq!(
            pending_prompt.message.as_deref(),
            Some("Approve the file write?")
        );
        assert_eq!(pending_prompt.questions.len(), 1);
        assert_eq!(
            pending_prompt.questions[0].header.as_deref(),
            Some("Approval")
        );
        assert_eq!(
            pending_prompt.questions[0].option_labels(),
            vec!["Allow", "Deny"]
        );
    }

    #[test]
    fn matching_tool_result_clears_pending_prompt() {
        let summary = agent_activity_summary_from_events(
            "agent-alpha",
            "claude",
            None,
            &[
                tool_invocation(
                    1,
                    "ask-1",
                    "AskUserQuestion",
                    json!({
                        "questions": [{
                            "question": "Approve the file write?",
                            "options": [{ "label": "Allow", "description": "Proceed with the write" }],
                            "multi_select": false
                        }]
                    }),
                ),
                tool_result(2, "ask-1", "AskUserQuestion"),
            ],
        );

        assert!(summary.pending_user_prompt.is_none());
    }

    #[test]
    fn flat_ask_user_invocation_still_surfaces_pending_prompt() {
        let summary = agent_activity_summary_from_events(
            "agent-alpha",
            "claude",
            None,
            &[tool_invocation(
                1,
                "ask-2",
                "ask_user",
                json!({ "message": "Continue?" }),
            )],
        );

        let pending_prompt = summary
            .pending_user_prompt
            .expect("expected legacy ask_user prompt");
        assert_eq!(pending_prompt.tool_name, "ask_user");
        assert_eq!(pending_prompt.message.as_deref(), Some("Continue?"));
        assert_eq!(pending_prompt.questions.len(), 1);
        assert!(pending_prompt.questions[0].options.is_empty());
    }

    fn tool_invocation(
        sequence: u64,
        invocation_id: &str,
        tool_name: &str,
        input: Value,
    ) -> ConversationEvent {
        ConversationEvent {
            timestamp: Some(format!("2026-04-28T08:00:{sequence:02}Z")),
            sequence,
            kind: ConversationEventKind::ToolInvocation {
                tool_name: tool_name.into(),
                category: "interaction".into(),
                input,
                invocation_id: Some(invocation_id.into()),
            },
            agent: "agent-alpha".into(),
            session_id: "session-1".into(),
        }
    }

    fn tool_result(sequence: u64, invocation_id: &str, tool_name: &str) -> ConversationEvent {
        ConversationEvent {
            timestamp: Some(format!("2026-04-28T08:00:{sequence:02}Z")),
            sequence,
            kind: ConversationEventKind::ToolResult {
                tool_name: tool_name.into(),
                invocation_id: Some(invocation_id.into()),
                output: json!({ "status": "answered" }),
                is_error: false,
                duration_ms: Some(120),
            },
            agent: "agent-alpha".into(),
            session_id: "session-1".into(),
        }
    }
}
