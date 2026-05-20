//! Wire types for the `OpenRouter` Chat Completions API.
//!
//! Mirrors the `OpenAI` Chat Completions schema with `OpenRouter`'s `reasoning`
//! extension. All optional fields use `skip_serializing_if` so emitted JSON
//! matches the smallest documented request shape.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ChatRole {
    System,
    User,
    Assistant,
    Tool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChatMessage {
    pub role: ChatRole,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    /// Required when `role == Tool`; identifies which assistant `tool_call` this
    /// message responds to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    /// Optional speaker name; ignored by most models.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Tool invocations the assistant produced in this turn.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<AssistantToolCall>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AssistantToolCall {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: AssistantToolCallKind,
    pub function: AssistantToolCallFunction,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AssistantToolCallKind {
    Function,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AssistantToolCallFunction {
    pub name: String,
    /// JSON-encoded argument string as the model emitted it. Kept as a string
    /// (not `Value`) because providers stream this incrementally and only the
    /// final concatenation is guaranteed to parse.
    pub arguments: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChatRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
    pub stream: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub tools: Vec<ToolDefinition>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_choice: Option<ToolChoice>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parallel_tool_calls: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<ReasoningRequest>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ToolDefinition {
    #[serde(rename = "type")]
    pub kind: ToolDefinitionKind,
    pub function: ToolDefinitionFunction,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolDefinitionKind {
    Function,
}

#[derive(Debug, Clone, Serialize)]
pub struct ToolDefinitionFunction {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// JSON Schema describing the function's argument object.
    pub parameters: Value,
}

#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub enum ToolChoice {
    Mode(ToolChoiceMode),
    Specific {
        #[serde(rename = "type")]
        kind: ToolDefinitionKind,
        function: ToolChoiceFunction,
    },
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolChoiceMode {
    None,
    Auto,
    Required,
}

#[derive(Debug, Clone, Serialize)]
pub struct ToolChoiceFunction {
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ReasoningRequest {
    /// Maps to `OpenRouter`'s `reasoning.effort` field (`low` / `medium` /
    /// `high` for reasoning-capable models).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    /// If true, returns reasoning text in the stream chunks; if false, the
    /// model still thinks but does not stream the trace.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exclude: Option<bool>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct StreamChunk {
    pub id: String,
    #[serde(default)]
    pub model: String,
    pub choices: Vec<ChatChoiceStreamEvent>,
    #[serde(default)]
    pub usage: Option<Usage>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ChatChoiceStreamEvent {
    pub index: u32,
    pub delta: ChatChoiceDelta,
    #[serde(default)]
    pub finish_reason: Option<FinishReason>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
pub struct ChatChoiceDelta {
    #[serde(default)]
    pub role: Option<ChatRole>,
    #[serde(default)]
    pub content: Option<String>,
    /// `OpenRouter`'s reasoning trace, when the model emits one. Absent on
    /// non-reasoning models.
    #[serde(default)]
    pub reasoning: Option<String>,
    #[serde(default)]
    pub tool_calls: Vec<ToolCallDelta>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
pub struct ToolCallDelta {
    pub index: u32,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default, rename = "type")]
    pub kind: Option<AssistantToolCallKind>,
    #[serde(default)]
    pub function: Option<ToolCallFunctionDelta>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
pub struct ToolCallFunctionDelta {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub arguments: Option<String>,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FinishReason {
    Stop,
    Length,
    ToolCalls,
    ContentFilter,
    Error,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
pub struct Usage {
    #[serde(default)]
    pub prompt_tokens: u32,
    #[serde(default)]
    pub completion_tokens: u32,
    #[serde(default)]
    pub total_tokens: u32,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ModelListResponse {
    pub data: Vec<ModelEntry>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ModelEntry {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub context_length: Option<u64>,
    #[serde(default)]
    pub supported_parameters: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn omits_empty_tool_arrays() {
        let request = ChatRequest {
            model: "anthropic/claude-3.7-sonnet".to_owned(),
            messages: vec![ChatMessage {
                role: ChatRole::User,
                content: Some("hello".to_owned()),
                tool_call_id: None,
                name: None,
                tool_calls: Vec::new(),
            }],
            stream: true,
            tools: Vec::new(),
            tool_choice: None,
            parallel_tool_calls: None,
            reasoning: None,
            temperature: None,
            max_tokens: None,
        };
        let serialized = serde_json::to_value(&request).expect("serialize");
        assert!(serialized.get("tools").is_none(), "empty tools elided");
        assert!(serialized.get("tool_choice").is_none(), "tool_choice elided");
        assert_eq!(serialized["stream"], json!(true));
    }

    #[test]
    fn parses_tool_call_delta() {
        let chunk: StreamChunk = serde_json::from_value(json!({
            "id": "gen-1",
            "model": "anthropic/claude-3.7-sonnet",
            "choices": [{
                "index": 0,
                "delta": {
                    "tool_calls": [{
                        "index": 0,
                        "id": "call_abc",
                        "type": "function",
                        "function": {"name": "read_text_file", "arguments": "{\"path"}
                    }]
                }
            }]
        }))
        .expect("parse chunk");
        let tool_call = &chunk.choices[0].delta.tool_calls[0];
        assert_eq!(tool_call.id.as_deref(), Some("call_abc"));
        assert_eq!(
            tool_call.function.as_ref().and_then(|f| f.name.as_deref()),
            Some("read_text_file"),
        );
    }

    #[test]
    fn parses_reasoning_delta() {
        let chunk: StreamChunk = serde_json::from_value(json!({
            "id": "gen-1",
            "choices": [{
                "index": 0,
                "delta": {"reasoning": "Let me think step by step..."}
            }]
        }))
        .expect("parse reasoning chunk");
        assert_eq!(
            chunk.choices[0].delta.reasoning.as_deref(),
            Some("Let me think step by step..."),
        );
    }
}
