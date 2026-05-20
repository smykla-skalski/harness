//! Tool dispatch: translates a finalized OpenRouter `tool_calls` entry into
//! the equivalent ACP request, sends it to the daemon-side ACP client, and
//! returns the result as a JSON value the model can read on the next turn.
//!
//! Errors are encoded as `{"error": "..."}` so the model can read the failure
//! and adapt; only invalid argument JSON or unknown tool names short-circuit
//! the loop.

use std::path::{Path, PathBuf};

use agent_client_protocol::schema::{
    CreateTerminalRequest, KillTerminalRequest, ReadTextFileRequest, ReleaseTerminalRequest,
    SessionId, TerminalId, TerminalOutputRequest, WaitForTerminalExitRequest, WriteTextFileRequest,
};
use agent_client_protocol::{Client, ConnectionTo};
use serde::Deserialize;
use serde_json::{Value, json};

use super::tool_translator::{
    TOOL_CREATE_TERMINAL, TOOL_KILL_TERMINAL, TOOL_READ_TEXT_FILE, TOOL_RELEASE_TERMINAL,
    TOOL_TERMINAL_OUTPUT, TOOL_WAIT_FOR_TERMINAL_EXIT, TOOL_WRITE_TEXT_FILE,
};

/// Dispatch a single finalized tool call. Returns the JSON value that will
/// become the next turn's `role: tool` content.
pub async fn dispatch_tool_call(
    connection: &ConnectionTo<Client>,
    session_id: &SessionId,
    project_dir: &Path,
    name: &str,
    arguments: &str,
) -> Value {
    let parsed = match serde_json::from_str::<Value>(arguments) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid arguments JSON: {error}")),
    };
    match name {
        TOOL_READ_TEXT_FILE => dispatch_read(connection, session_id, project_dir, &parsed).await,
        TOOL_WRITE_TEXT_FILE => dispatch_write(connection, session_id, project_dir, &parsed).await,
        TOOL_CREATE_TERMINAL => {
            dispatch_create_terminal(connection, session_id, project_dir, &parsed).await
        }
        TOOL_TERMINAL_OUTPUT => dispatch_terminal_output(connection, session_id, &parsed).await,
        TOOL_WAIT_FOR_TERMINAL_EXIT => dispatch_wait_for_exit(connection, session_id, &parsed).await,
        TOOL_KILL_TERMINAL => dispatch_kill(connection, session_id, &parsed).await,
        TOOL_RELEASE_TERMINAL => dispatch_release(connection, session_id, &parsed).await,
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

async fn dispatch_read(
    connection: &ConnectionTo<Client>,
    session_id: &SessionId,
    project_dir: &Path,
    args: &Value,
) -> Value {
    let parsed: ReadArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid read arguments: {error}")),
    };
    let resolved = resolve_path(project_dir, &parsed.path);
    let mut request = ReadTextFileRequest::new(session_id.clone(), resolved);
    request.line = parsed.line;
    request.limit = parsed.limit;
    match connection.send_request(request).block_task().await {
        Ok(response) => json!({ "content": response.content }),
        Err(error) => acp_error_value(&error),
    }
}

#[derive(Debug, Deserialize)]
struct WriteArgs {
    path: String,
    content: String,
}

async fn dispatch_write(
    connection: &ConnectionTo<Client>,
    session_id: &SessionId,
    project_dir: &Path,
    args: &Value,
) -> Value {
    let parsed: WriteArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid write arguments: {error}")),
    };
    let resolved = resolve_path(project_dir, &parsed.path);
    let request = WriteTextFileRequest::new(session_id.clone(), resolved, parsed.content);
    match connection.send_request(request).block_task().await {
        Ok(_) => json!({ "ok": true }),
        Err(error) => acp_error_value(&error),
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

async fn dispatch_create_terminal(
    connection: &ConnectionTo<Client>,
    session_id: &SessionId,
    project_dir: &Path,
    args: &Value,
) -> Value {
    let parsed: CreateTerminalArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid create_terminal arguments: {error}")),
    };
    let mut request = CreateTerminalRequest::new(session_id.clone(), parsed.command);
    request.args = parsed.args;
    request.cwd = parsed.cwd.map(|cwd| resolve_path(project_dir, &cwd));
    request.output_byte_limit = parsed.output_byte_limit;
    match connection.send_request(request).block_task().await {
        Ok(response) => json!({ "terminal_id": response.terminal_id.0.as_ref() }),
        Err(error) => acp_error_value(&error),
    }
}

#[derive(Debug, Deserialize)]
struct TerminalIdArgs {
    terminal_id: String,
}

async fn dispatch_terminal_output(
    connection: &ConnectionTo<Client>,
    session_id: &SessionId,
    args: &Value,
) -> Value {
    let parsed: TerminalIdArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid terminal_output arguments: {error}")),
    };
    let request = TerminalOutputRequest::new(session_id.clone(), TerminalId::new(parsed.terminal_id));
    match connection.send_request(request).block_task().await {
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
        Err(error) => acp_error_value(&error),
    }
}

async fn dispatch_wait_for_exit(
    connection: &ConnectionTo<Client>,
    session_id: &SessionId,
    args: &Value,
) -> Value {
    let parsed: TerminalIdArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => {
            return error_value(&format!("invalid wait_for_terminal_exit arguments: {error}"));
        }
    };
    let request =
        WaitForTerminalExitRequest::new(session_id.clone(), TerminalId::new(parsed.terminal_id));
    match connection.send_request(request).block_task().await {
        Ok(response) => json!({
            "exit_code": response.exit_status.exit_code,
            "signal": response.exit_status.signal,
        }),
        Err(error) => acp_error_value(&error),
    }
}

async fn dispatch_kill(
    connection: &ConnectionTo<Client>,
    session_id: &SessionId,
    args: &Value,
) -> Value {
    let parsed: TerminalIdArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid kill_terminal arguments: {error}")),
    };
    let request =
        KillTerminalRequest::new(session_id.clone(), TerminalId::new(parsed.terminal_id));
    match connection.send_request(request).block_task().await {
        Ok(_) => json!({ "ok": true }),
        Err(error) => acp_error_value(&error),
    }
}

async fn dispatch_release(
    connection: &ConnectionTo<Client>,
    session_id: &SessionId,
    args: &Value,
) -> Value {
    let parsed: TerminalIdArgs = match serde_json::from_value(args.clone()) {
        Ok(value) => value,
        Err(error) => return error_value(&format!("invalid release_terminal arguments: {error}")),
    };
    let request =
        ReleaseTerminalRequest::new(session_id.clone(), TerminalId::new(parsed.terminal_id));
    match connection.send_request(request).block_task().await {
        Ok(_) => json!({ "ok": true }),
        Err(error) => acp_error_value(&error),
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

fn acp_error_value(error: &agent_client_protocol::Error) -> Value {
    json!({ "error": format!("{}: {}", error.code, error.message) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_relative_path_joins_project_dir() {
        let resolved = resolve_path(Path::new("/work/proj"), "src/lib.rs");
        assert_eq!(resolved, PathBuf::from("/work/proj/src/lib.rs"));
    }

    #[test]
    fn resolve_absolute_path_unchanged() {
        let resolved = resolve_path(Path::new("/work/proj"), "/etc/hosts");
        assert_eq!(resolved, PathBuf::from("/etc/hosts"));
    }

    #[test]
    fn error_value_shape_is_stable() {
        let err = error_value("nope");
        assert_eq!(err, json!({ "error": "nope" }));
    }
}
