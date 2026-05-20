//! Tool catalog + dispatch for the in-daemon `OpenRouter` backend.
//!
//! Streaming `tool_calls` deltas arrive interleaved with text content and are
//! accumulated by `index` until the choice reports
//! `finish_reason: ToolCalls`. The finalized list is dispatched through
//! [`HarnessAcpClient`] so the model sees the same file-surface guard,
//! denied-binary check, and terminal cap as ACP-managed agents. Tool results
//! are returned as JSON-serializable values and fed back to the model as
//! `role: tool` messages on the next turn.
//!
//! The catalog mirrors the ACP client's tool surface: file IO plus the full
//! terminal lifecycle (create / output / wait / kill / release). Every tool
//! definition uses JSON Schema draft-07 vocabulary so all upstream providers
//! routed through `OpenRouter` accept the shape.
//!
//! Cross-version pluggability is intentionally absent: the catalog is a
//! constant compile-time list, not configurable per session.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use agent_client_protocol::schema::{
    CreateTerminalRequest, KillTerminalRequest, ReadTextFileRequest, ReleaseTerminalRequest,
    SessionId, TerminalId, TerminalOutputRequest, WaitForTerminalExitRequest,
    WriteTextFileRequest,
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::agents::acp::client::HarnessAcpClient;
use crate::agents::openrouter::{
    AssistantToolCall, AssistantToolCallFunction, AssistantToolCallKind, ToolCallDelta,
    ToolDefinition, ToolDefinitionFunction, ToolDefinitionKind,
};

/// Tool name advertised to the model.
pub const TOOL_READ_TEXT_FILE: &str = "read_text_file";
/// Tool name advertised to the model.
pub const TOOL_WRITE_TEXT_FILE: &str = "write_text_file";
/// Tool name advertised to the model.
pub const TOOL_CREATE_TERMINAL: &str = "create_terminal";
/// Tool name advertised to the model.
pub const TOOL_TERMINAL_OUTPUT: &str = "terminal_output";
/// Tool name advertised to the model.
pub const TOOL_WAIT_FOR_TERMINAL_EXIT: &str = "wait_for_terminal_exit";
/// Tool name advertised to the model.
pub const TOOL_KILL_TERMINAL: &str = "kill_terminal";
/// Tool name advertised to the model.
pub const TOOL_RELEASE_TERMINAL: &str = "release_terminal";

/// Fixed catalog handed to the model on every turn.
#[must_use]
pub fn tool_catalog() -> Vec<ToolDefinition> {
    vec![
        read_text_file_definition(),
        write_text_file_definition(),
        create_terminal_definition(),
        terminal_output_definition(),
        wait_for_terminal_exit_definition(),
        kill_terminal_definition(),
        release_terminal_definition(),
    ]
}

/// Partial tool call assembled from streaming deltas, keyed by the `OpenAI`
/// `index` in `ChatChoiceDelta::tool_calls`. The `id` and `name` arrive in
/// the first delta for a given index; `arguments` is concatenated across
/// every subsequent delta with the same index until the turn finalizes.
#[derive(Debug, Default, Clone)]
pub struct PartialToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

/// Apply a streaming tool-call delta to the accumulator.
pub fn absorb_tool_call_delta(
    accumulator: &mut BTreeMap<u32, PartialToolCall>,
    delta: ToolCallDelta,
) {
    let entry = accumulator.entry(delta.index).or_default();
    if let Some(id) = delta.id {
        entry.id = id;
    }
    if let Some(function) = delta.function {
        if let Some(name) = function.name {
            entry.name = name;
        }
        if let Some(arguments) = function.arguments {
            entry.arguments.push_str(&arguments);
        }
    }
}

/// Convert the index-keyed accumulator into the assistant-message tool-call
/// list. Ordering follows the index, matching how providers emit the calls.
#[must_use]
pub fn finalize_tool_calls(accumulator: BTreeMap<u32, PartialToolCall>) -> Vec<AssistantToolCall> {
    accumulator
        .into_values()
        .map(|partial| AssistantToolCall {
            id: partial.id,
            kind: AssistantToolCallKind::Function,
            function: AssistantToolCallFunction {
                name: partial.name,
                arguments: partial.arguments,
            },
        })
        .collect()
}

/// Execute a single tool call. Returns a JSON `Value` representing the body
/// the model receives as the `tool` message content. Errors are encoded as
/// `{"error": "..."}` so the model can read the failure and try again rather
/// than the turn being aborted.
#[must_use]
pub fn dispatch_tool_call(
    client: &HarnessAcpClient,
    session_id: &str,
    project_dir: &Path,
    name: &str,
    arguments: &str,
) -> Value {
    let parsed = match serde_json::from_str::<Value>(arguments) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid arguments JSON: {error}")),
    };
    match name {
        TOOL_READ_TEXT_FILE => dispatch_read(client, session_id, project_dir, &parsed),
        TOOL_WRITE_TEXT_FILE => dispatch_write(client, session_id, project_dir, &parsed),
        TOOL_CREATE_TERMINAL => dispatch_create_terminal(client, session_id, project_dir, &parsed),
        TOOL_TERMINAL_OUTPUT => dispatch_terminal_output(client, session_id, &parsed),
        TOOL_WAIT_FOR_TERMINAL_EXIT => dispatch_wait_for_exit(client, session_id, &parsed),
        TOOL_KILL_TERMINAL => dispatch_kill_terminal(client, session_id, &parsed),
        TOOL_RELEASE_TERMINAL => dispatch_release_terminal(client, session_id, &parsed),
        other => error_value(&format!("unknown tool: {other}")),
    }
}

#[derive(Debug, Deserialize)]
struct ReadArgs {
    path: String,
    #[serde(default)]
    line: Option<u32>,
    #[serde(default)]
    limit: Option<u32>,
}

fn dispatch_read(
    client: &HarnessAcpClient,
    session_id: &str,
    project_dir: &Path,
    args: &Value,
) -> Value {
    let parsed: ReadArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid read arguments: {error}")),
    };
    let resolved = resolve_path(project_dir, &parsed.path);
    let mut request = ReadTextFileRequest::new(SessionId::new(session_id), resolved);
    request.line = parsed.line;
    request.limit = parsed.limit;
    match client.handle_read_text_file(&request) {
        Ok(response) => json!({ "content": response.content }),
        Err(error) => error_value(&format!("{}: {}", error.code, error.message)),
    }
}

#[derive(Debug, Deserialize)]
struct WriteArgs {
    path: String,
    content: String,
}

fn dispatch_write(
    client: &HarnessAcpClient,
    session_id: &str,
    project_dir: &Path,
    args: &Value,
) -> Value {
    let parsed: WriteArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid write arguments: {error}")),
    };
    let resolved = resolve_path(project_dir, &parsed.path);
    let request =
        WriteTextFileRequest::new(SessionId::new(session_id), resolved, parsed.content);
    match client.handle_write_text_file(&request) {
        Ok(_) => json!({ "ok": true }),
        Err(error) => error_value(&format!("{}: {}", error.code, error.message)),
    }
}

#[derive(Debug, Deserialize)]
struct CreateTerminalArgs {
    command: String,
    #[serde(default)]
    args: Vec<String>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    output_byte_limit: Option<u64>,
}

fn dispatch_create_terminal(
    client: &HarnessAcpClient,
    session_id: &str,
    project_dir: &Path,
    args: &Value,
) -> Value {
    let parsed: CreateTerminalArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid create_terminal arguments: {error}")),
    };
    let mut request = CreateTerminalRequest::new(SessionId::new(session_id), parsed.command);
    request.args = parsed.args;
    request.cwd = parsed.cwd.map(|cwd| resolve_path(project_dir, &cwd));
    request.output_byte_limit = parsed.output_byte_limit;
    match client.handle_create_terminal(&request) {
        Ok(response) => json!({ "terminal_id": response.terminal_id.0.as_ref() }),
        Err(error) => error_value(&format!("{}: {}", error.code, error.message)),
    }
}

#[derive(Debug, Deserialize)]
struct TerminalIdArgs {
    terminal_id: String,
}

fn dispatch_terminal_output(client: &HarnessAcpClient, session_id: &str, args: &Value) -> Value {
    let parsed: TerminalIdArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid terminal_output arguments: {error}")),
    };
    let request = TerminalOutputRequest::new(
        SessionId::new(session_id),
        TerminalId::new(parsed.terminal_id),
    );
    match client.handle_terminal_output(&request) {
        Ok(response) => {
            let mut payload = json!({
                "output": response.output,
                "truncated": response.truncated,
            });
            if let Some(exit) = response.exit_status {
                payload["exit_status"] = json!({
                    "exit_code": exit.exit_code,
                    "signal": exit.signal,
                });
            }
            payload
        }
        Err(error) => error_value(&format!("{}: {}", error.code, error.message)),
    }
}

fn dispatch_wait_for_exit(client: &HarnessAcpClient, session_id: &str, args: &Value) -> Value {
    let parsed: TerminalIdArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => {
            return error_value(&format!("invalid wait_for_terminal_exit arguments: {error}"));
        }
    };
    let request = WaitForTerminalExitRequest::new(
        SessionId::new(session_id),
        TerminalId::new(parsed.terminal_id),
    );
    match client.handle_wait_for_terminal_exit(&request) {
        Ok(response) => json!({
            "exit_code": response.exit_status.exit_code,
            "signal": response.exit_status.signal,
        }),
        Err(error) => error_value(&format!("{}: {}", error.code, error.message)),
    }
}

fn dispatch_kill_terminal(client: &HarnessAcpClient, session_id: &str, args: &Value) -> Value {
    let parsed: TerminalIdArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid kill_terminal arguments: {error}")),
    };
    let request = KillTerminalRequest::new(
        SessionId::new(session_id),
        TerminalId::new(parsed.terminal_id),
    );
    match client.handle_kill_terminal(&request) {
        Ok(_) => json!({ "ok": true }),
        Err(error) => error_value(&format!("{}: {}", error.code, error.message)),
    }
}

fn dispatch_release_terminal(client: &HarnessAcpClient, session_id: &str, args: &Value) -> Value {
    let parsed: TerminalIdArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid release_terminal arguments: {error}")),
    };
    let request = ReleaseTerminalRequest::new(
        SessionId::new(session_id),
        TerminalId::new(parsed.terminal_id),
    );
    match client.handle_release_terminal(&request) {
        Ok(_) => json!({ "ok": true }),
        Err(error) => error_value(&format!("{}: {}", error.code, error.message)),
    }
}

fn resolve_path(project_dir: &Path, requested: &str) -> PathBuf {
    let path = PathBuf::from(requested);
    if path.is_absolute() {
        path
    } else {
        project_dir.join(path)
    }
}

fn error_value(message: &str) -> Value {
    json!({ "error": message })
}

fn read_text_file_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_READ_TEXT_FILE.to_owned(),
            description: Some(
                "Read a text file from the workspace. Relative paths resolve \
                 against the project root."
                    .to_owned(),
            ),
            parameters: json!({
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path to the file (absolute or relative to project root)."
                    },
                    "line": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "1-based line number to start reading from."
                    },
                    "limit": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "Maximum number of lines to read."
                    }
                },
                "required": ["path"],
                "additionalProperties": false
            }),
        },
    }
}

fn write_text_file_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_WRITE_TEXT_FILE.to_owned(),
            description: Some(
                "Write a text file inside the run surface. Writes outside the \
                 surface or to control files are rejected."
                    .to_owned(),
            ),
            parameters: json!({
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path to the file (absolute or relative to project root)."
                    },
                    "content": {
                        "type": "string",
                        "description": "Full file contents to write."
                    }
                },
                "required": ["path", "content"],
                "additionalProperties": false
            }),
        },
    }
}

fn create_terminal_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_CREATE_TERMINAL.to_owned(),
            description: Some(
                "Spawn a shell command in a managed terminal and return its id. \
                 Denied binaries and surface escapes are rejected."
                    .to_owned(),
            ),
            parameters: json!({
                "type": "object",
                "properties": {
                    "command": { "type": "string", "description": "Program to spawn." },
                    "args": {
                        "type": "array",
                        "items": { "type": "string" },
                        "description": "Arguments passed to the program."
                    },
                    "cwd": {
                        "type": "string",
                        "description": "Working directory (relative to project root or absolute)."
                    },
                    "output_byte_limit": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "Maximum captured output bytes; older bytes are dropped."
                    }
                },
                "required": ["command"],
                "additionalProperties": false
            }),
        },
    }
}

fn terminal_output_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_TERMINAL_OUTPUT.to_owned(),
            description: Some(
                "Read the current captured output from a terminal. Returns the \
                 retained bytes and the exit status once the process completes."
                    .to_owned(),
            ),
            parameters: terminal_id_schema(),
        },
    }
}

fn wait_for_terminal_exit_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_WAIT_FOR_TERMINAL_EXIT.to_owned(),
            description: Some("Block until a terminal exits and return its status.".to_owned()),
            parameters: terminal_id_schema(),
        },
    }
}

fn kill_terminal_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_KILL_TERMINAL.to_owned(),
            description: Some("Send SIGKILL to a terminal without releasing it.".to_owned()),
            parameters: terminal_id_schema(),
        },
    }
}

fn release_terminal_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_RELEASE_TERMINAL.to_owned(),
            description: Some("Release a terminal's id slot for reuse.".to_owned()),
            parameters: terminal_id_schema(),
        },
    }
}

fn terminal_id_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "terminal_id": { "type": "string", "description": "Terminal id from create_terminal." }
        },
        "required": ["terminal_id"],
        "additionalProperties": false
    })
}

#[cfg(test)]
mod tests;
