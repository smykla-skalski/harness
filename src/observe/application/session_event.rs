use serde_json::Value;

/// Parsed session event from a transcript JSONL line.
#[derive(Debug, Clone)]
pub struct SessionEvent {
    pub timestamp: Option<String>,
    pub message: SessionMessage,
}

/// Parsed session message payload.
#[derive(Debug, Clone)]
pub struct SessionMessage {
    pub role: String,
    pub content: SessionContent,
}

/// Message content normalized to either plain text or structured blocks.
#[derive(Debug, Clone)]
pub enum SessionContent {
    Text(String),
    Blocks(Vec<SessionContentBlock>),
}

/// Structured content blocks carried inside a session message.
#[derive(Debug, Clone)]
pub enum SessionContentBlock {
    Text(String),
    ToolUse(Value),
    ToolResult(Value),
    Other,
}

/// Parse one raw transcript line into a typed session event.
#[must_use]
pub fn parse_session_event(raw: &str) -> Option<SessionEvent> {
    let obj: Value = serde_json::from_str(raw.trim()).ok()?;
    let message = obj.get("message")?;
    if !message.is_object() {
        return None;
    }

    let role = message.get("role")?.as_str()?.to_string();
    let content = parse_content(message.get("content")?)?;

    Some(SessionEvent {
        timestamp: obj
            .get("timestamp")
            .and_then(Value::as_str)
            .map(ToString::to_string),
        message: SessionMessage { role, content },
    })
}

fn parse_content(value: &Value) -> Option<SessionContent> {
    if let Some(blocks) = value.as_array() {
        return Some(SessionContent::Blocks(
            blocks.iter().map(parse_block).collect(),
        ));
    }
    value
        .as_str()
        .map(|text| SessionContent::Text(text.to_string()))
}

fn parse_block(block: &Value) -> SessionContentBlock {
    match block.get("type").and_then(Value::as_str) {
        Some("text") => SessionContentBlock::Text(
            block
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        ),
        Some("tool_use") => SessionContentBlock::ToolUse(block.clone()),
        Some("tool_result") => SessionContentBlock::ToolResult(block.clone()),
        _ => SessionContentBlock::Other,
    }
}
