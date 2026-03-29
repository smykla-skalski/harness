use std::fs;
use std::path::{Path, PathBuf};

use crate::errors::CliError;
use crate::workspace::project_context_dir;

use super::event::{ConversationEvent, ConversationEventKind};
use super::signal::{Signal, SignalAck};
use super::{AgentRuntime, HookIntegrationPoint};

pub struct ClaudeRuntime;

const HOOK_POINTS: &[HookIntegrationPoint] = &[
    HookIntegrationPoint {
        name: "PreToolUse",
        typical_latency_seconds: 5,
        supports_context_injection: true,
    },
    HookIntegrationPoint {
        name: "PostToolUse",
        typical_latency_seconds: 5,
        supports_context_injection: false,
    },
];

impl AgentRuntime for ClaudeRuntime {
    fn name(&self) -> &'static str {
        "claude"
    }

    fn discover_native_log(
        &self,
        session_id: &str,
        project_dir: &Path,
    ) -> Result<Option<PathBuf>, CliError> {
        // Claude transcripts: ~/.claude/projects/{project_hash}/{session_id}.jsonl
        let candidates = [project_context_dir(project_dir)
            .join("agents/sessions/claude")
            .join(session_id)
            .join("raw.jsonl")];
        Ok(candidates.into_iter().find(|path| path.is_file()))
    }

    fn parse_log_entry(&self, raw_line: &str) -> Option<ConversationEvent> {
        parse_common_jsonl(raw_line, "claude")
    }

    fn signal_dir(&self, project_dir: &Path, session_id: &str) -> PathBuf {
        project_context_dir(project_dir)
            .join("agents/signals/claude")
            .join(session_id)
    }

    fn write_signal(
        &self,
        project_dir: &Path,
        session_id: &str,
        signal: &Signal,
    ) -> Result<PathBuf, CliError> {
        super::signal::write_signal_file(&self.signal_dir(project_dir, session_id), signal)
    }

    fn read_acknowledgments(
        &self,
        project_dir: &Path,
        session_id: &str,
    ) -> Result<Vec<SignalAck>, CliError> {
        super::signal::read_acknowledgments(&self.signal_dir(project_dir, session_id))
    }

    fn last_activity(
        &self,
        project_dir: &Path,
        session_id: &str,
    ) -> Result<Option<String>, CliError> {
        last_activity_from_log(self, session_id, project_dir)
    }

    fn hook_integration_points(&self) -> &[HookIntegrationPoint] {
        HOOK_POINTS
    }
}

/// Parse a JSONL line using the common transcript format shared by all runtimes.
pub(crate) fn parse_common_jsonl(raw_line: &str, agent: &str) -> Option<ConversationEvent> {
    let obj: serde_json::Value = serde_json::from_str(raw_line.trim()).ok()?;
    let message = obj.get("message")?;
    let role = message.get("role")?.as_str()?;
    let timestamp = obj
        .get("timestamp")
        .and_then(serde_json::Value::as_str)
        .map(ToString::to_string);

    let content = message.get("content")?;
    let kind = if let Some(text) = content.as_str() {
        match role {
            "user" => ConversationEventKind::UserPrompt {
                content: text.to_string(),
            },
            _ => ConversationEventKind::AssistantText {
                content: text.to_string(),
            },
        }
    } else if let Some(blocks) = content.as_array() {
        parse_first_block(blocks, role)?
    } else {
        return None;
    };

    Some(ConversationEvent {
        timestamp,
        sequence: 0,
        kind,
        agent: agent.to_string(),
        session_id: String::new(),
    })
}

fn parse_first_block(blocks: &[serde_json::Value], role: &str) -> Option<ConversationEventKind> {
    let block = blocks.first()?;
    match block.get("type")?.as_str()? {
        "text" => {
            let text = block.get("text")?.as_str()?.to_string();
            Some(match role {
                "user" => ConversationEventKind::UserPrompt { content: text },
                _ => ConversationEventKind::AssistantText { content: text },
            })
        }
        "tool_use" => Some(ConversationEventKind::ToolInvocation {
            tool_name: block
                .get("name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("unknown")
                .to_string(),
            category: "unknown".to_string(),
            input: block
                .get("input")
                .cloned()
                .unwrap_or(serde_json::Value::Null),
            invocation_id: block
                .get("id")
                .and_then(serde_json::Value::as_str)
                .map(ToString::to_string),
        }),
        "tool_result" => {
            let output = block
                .get("content")
                .cloned()
                .unwrap_or(serde_json::Value::Null);
            let is_error = block
                .get("is_error")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false);
            Some(ConversationEventKind::ToolResult {
                tool_name: block
                    .get("tool_name")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("unknown")
                    .to_string(),
                invocation_id: block
                    .get("tool_use_id")
                    .and_then(serde_json::Value::as_str)
                    .map(ToString::to_string),
                output,
                is_error,
                duration_ms: None,
            })
        }
        _ => Some(ConversationEventKind::Other {
            label: "unknown_block".to_string(),
            data: block.clone(),
        }),
    }
}

/// Derive last activity timestamp from the last line of an agent's log file.
pub(super) fn last_activity_from_log(
    runtime: &dyn AgentRuntime,
    session_id: &str,
    project_dir: &Path,
) -> Result<Option<String>, CliError> {
    let Some(log_path) = runtime.discover_native_log(session_id, project_dir)? else {
        return Ok(None);
    };
    let Ok(metadata) = fs::metadata(&log_path) else {
        return Ok(None);
    };
    let Ok(modified) = metadata.modified() else {
        return Ok(None);
    };
    let datetime: chrono::DateTime<chrono::Utc> = modified.into();
    Ok(Some(datetime.to_rfc3339()))
}

#[cfg(test)]
mod tests {
    use super::{ConversationEventKind, parse_common_jsonl};

    #[test]
    fn parse_common_jsonl_keeps_tool_name_for_tool_result_blocks() {
        let raw = serde_json::json!({
            "timestamp": "2026-03-28T14:05:00Z",
            "message": {
                "role": "assistant",
                "content": [{
                    "type": "tool_result",
                    "tool_name": "Read",
                    "tool_use_id": "call-1",
                    "content": {"line_count": 8},
                    "is_error": false
                }]
            }
        })
        .to_string();

        let event = parse_common_jsonl(&raw, "claude").expect("event");
        match event.kind {
            ConversationEventKind::ToolResult {
                tool_name,
                invocation_id,
                is_error,
                ..
            } => {
                assert_eq!(tool_name, "Read");
                assert_eq!(invocation_id.as_deref(), Some("call-1"));
                assert!(!is_error);
            }
            other => panic!("unexpected event kind: {other:?}"),
        }
    }
}
