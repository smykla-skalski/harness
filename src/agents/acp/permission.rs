//! Permission gateway modes for ACP `session/request_permission`.
//!
//! No trait, no abstraction: the gateway is a direct `match` at the call site.
//! `Recording` captures dogfood data without granting permissions.

use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::SyncSender;
use std::time::Duration;

use agent_client_protocol::schema::{
    CreateTerminalRequest, PermissionOption, PermissionOptionId, PermissionOptionKind,
    RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse,
    SelectedPermissionOutcome, WriteTextFileRequest,
};
use serde::Serialize;
use serde_json::json;
use tokio::sync::mpsc::Sender;

use crate::workspace::{harness_data_root, utc_now};

use super::client::ClientError;

/// File name used for ACP dogfood permission logs.
pub const PERMISSION_LOG_FILE: &str = "permission-log.ndjson";

/// Recording-mode operation name.
pub const OPERATION_REQUEST_PERMISSION: &str = "session.request_permission";
/// Recording-mode operation name.
pub const OPERATION_WRITE_TEXT_FILE: &str = "fs.write_text_file";
/// Recording-mode operation name.
pub const OPERATION_CREATE_TERMINAL: &str = "terminal.create";

/// Recording-mode decision value.
pub const DECISION_ALLOWED: &str = "allowed";
/// Recording-mode decision value.
pub const DECISION_DENIED: &str = "denied";
/// Recording-mode decision value.
pub const DECISION_RECORDED_REJECT: &str = "recorded_reject";

/// How `session/request_permission` requests are resolved.
///
/// The choice is per-session. Headless CLI uses `Stdin`. The daemon wires
/// `DaemonBridge` to surface permissions through the Swift modal. `Recording`
/// captures what *would* have been asked without blocking.
#[derive(Debug)]
pub enum PermissionMode {
    /// Never blocks. Logs the decision + what would have been asked.
    /// Wired in Chunk 10 for dogfood.
    Recording {
        /// Path to the permission log (NDJSON).
        log_path: PathBuf,
    },
    /// Sends permission requests over the daemon WS and awaits user response.
    /// Wired in Chunk 7.
    DaemonBridge {
        /// Channel to send permission requests to the daemon.
        tx: Sender<PermissionBridgeRequest>,
        /// Maximum time to wait for user response.
        deadline: Duration,
    },
    /// Reads permission responses from stdin. For headless CLI.
    Stdin,
}

/// Resolve the recording-mode log path for an ACP session.
#[must_use]
pub fn recording_log_path_for_session(session_id: &str) -> PathBuf {
    harness_data_root()
        .join("runs")
        .join(session_id)
        .join(PERMISSION_LOG_FILE)
}

/// Request sent over the daemon bridge channel.
#[derive(Debug)]
pub struct PermissionBridgeRequest {
    /// The original ACP request.
    pub request: RequestPermissionRequest,
    /// Channel to receive the user's response.
    pub response_tx: SyncSender<PermissionBridgeResult>,
}

/// Result sent back by the daemon permission bridge.
pub type PermissionBridgeResult = Result<RequestPermissionResponse, PermissionBridgeError>;

/// Structured bridge-side permission failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PermissionBridgeError {
    /// JSON-RPC error code to return to the ACP agent.
    pub code: i32,
    /// Human-readable error message.
    pub message: String,
}

impl PermissionBridgeError {
    /// Build a bridge error.
    #[must_use]
    pub fn new(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

/// Ask for permission via stdin.
///
/// Prints the permission options and reads the user's choice from stdin.
/// Returns `Cancelled` on EOF or parse error.
///
/// # Errors
///
/// Returns an I/O error if writing to stdout or reading from stdin fails.
pub fn stdin_permission_gateway(
    request: &RequestPermissionRequest,
) -> io::Result<RequestPermissionResponse> {
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    let mut input = stdin.lock();

    stdin_permission_gateway_from(request, &mut input, &mut stdout)
}

/// Record and reject a permission request without blocking.
///
/// # Errors
///
/// Returns an I/O error if the structured log cannot be appended.
pub fn recording_permission_gateway(
    log_path: &Path,
    request: &RequestPermissionRequest,
) -> io::Result<RequestPermissionResponse> {
    append_record(
        log_path,
        &PermissionLogRecord {
            timestamp: utc_now(),
            session_id: request.session_id.to_string(),
            operation: OPERATION_REQUEST_PERMISSION,
            decision: DECISION_RECORDED_REJECT,
            reason: Some("recording mode never approves session/request_permission"),
            would_ask: json!({
                "toolCall": request.tool_call,
                "options": request.options,
            }),
            runtime: json!({
                "outcome": "reject_once",
            }),
        },
    )?;
    Ok(recording_reject_response(request))
}

/// Record a write decision.
pub fn record_write_decision(
    log_path: &Path,
    request: &WriteTextFileRequest,
    decision: Result<(), &ClientError>,
) {
    let (decision_label, reason) = match decision {
        Ok(()) => (DECISION_ALLOWED, None),
        Err(error) => (DECISION_DENIED, Some(error.message.as_str())),
    };
    append_record_or_warn(
        log_path,
        &PermissionLogRecord {
            timestamp: utc_now(),
            session_id: request.session_id.to_string(),
            operation: OPERATION_WRITE_TEXT_FILE,
            decision: decision_label,
            reason,
            would_ask: json!({
                "path": request.path,
                "contentBytes": request.content.len(),
            }),
            runtime: json!({
                "policyDecision": decision_label,
            }),
        },
    );
}

/// Record a terminal-create decision.
pub fn record_terminal_decision(
    log_path: &Path,
    request: &CreateTerminalRequest,
    decision: Result<(), &ClientError>,
) {
    let (decision_label, reason) = match decision {
        Ok(()) => (DECISION_ALLOWED, None),
        Err(error) => (DECISION_DENIED, Some(error.message.as_str())),
    };
    append_record_or_warn(
        log_path,
        &PermissionLogRecord {
            timestamp: utc_now(),
            session_id: request.session_id.to_string(),
            operation: OPERATION_CREATE_TERMINAL,
            decision: decision_label,
            reason,
            would_ask: json!({
                "command": request.command,
                "args": request.args,
                "cwd": request.cwd,
            }),
            runtime: json!({
                "policyDecision": decision_label,
            }),
        },
    );
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PermissionLogRecord<'a> {
    timestamp: String,
    session_id: String,
    operation: &'static str,
    decision: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<&'a str>,
    would_ask: serde_json::Value,
    runtime: serde_json::Value,
}

fn append_record_or_warn(log_path: &Path, record: &PermissionLogRecord<'_>) {
    append_record(log_path, record).unwrap_or_else(|error| warn_append_error(log_path, &error));
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_append_error(log_path: &Path, error: &io::Error) {
    tracing::warn!(
        path = %log_path.display(),
        %error,
        "failed to append ACP permission recording"
    );
}

fn append_record(log_path: &Path, record: &PermissionLogRecord<'_>) -> io::Result<()> {
    if let Some(parent) = log_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)?;
    serde_json::to_writer(&mut file, record).map_err(io::Error::other)?;
    writeln!(file)?;
    Ok(())
}

fn recording_reject_response(request: &RequestPermissionRequest) -> RequestPermissionResponse {
    request
        .options
        .iter()
        .find(|option| {
            matches!(
                option.kind,
                PermissionOptionKind::RejectOnce | PermissionOptionKind::RejectAlways
            )
        })
        .map_or_else(
            || RequestPermissionResponse::new(RequestPermissionOutcome::Cancelled),
            |option| {
                RequestPermissionResponse::new(RequestPermissionOutcome::Selected(
                    SelectedPermissionOutcome::new(option.option_id.clone()),
                ))
            },
        )
}

fn stdin_permission_gateway_from(
    request: &RequestPermissionRequest,
    input: &mut impl BufRead,
    output: &mut impl Write,
) -> io::Result<RequestPermissionResponse> {
    writeln!(output, "\n=== Permission Request ===")?;
    writeln!(output, "Session: {}", request.session_id)?;
    writeln!(output, "Tool call: {:?}", request.tool_call)?;
    writeln!(output)?;

    if request.options.is_empty() {
        writeln!(output, "No permission options supplied; cancelling.")?;
        return Ok(RequestPermissionResponse::new(
            RequestPermissionOutcome::Cancelled,
        ));
    }

    for (i, option) in request.options.iter().enumerate() {
        let kind_label = match option.kind {
            PermissionOptionKind::AllowOnce => "[allow once]",
            PermissionOptionKind::AllowAlways => "[allow always]",
            PermissionOptionKind::RejectOnce => "[reject once]",
            PermissionOptionKind::RejectAlways => "[reject always]",
            _ => "[unknown]",
        };
        writeln!(output, "  {i}: {} {kind_label}", option.name)?;
    }
    writeln!(output)?;
    write!(output, "Enter choice (0-{}): ", request.options.len() - 1)?;
    output.flush()?;

    let mut line = String::new();
    let bytes_read = input.read_line(&mut line)?;
    if bytes_read == 0 {
        return Ok(RequestPermissionResponse::new(
            RequestPermissionOutcome::Cancelled,
        ));
    }

    let choice: usize = match line.trim().parse() {
        Ok(n) if n < request.options.len() => n,
        _ => {
            return Ok(RequestPermissionResponse::new(
                RequestPermissionOutcome::Cancelled,
            ));
        }
    };

    let selected = &request.options[choice];
    Ok(RequestPermissionResponse::new(
        RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
            selected.option_id.clone(),
        )),
    ))
}

/// Build the standard permission options for a tool call.
#[must_use]
pub fn standard_permission_options() -> Vec<PermissionOption> {
    vec![
        PermissionOption::new(
            PermissionOptionId::new("allow_once"),
            "Allow this action",
            PermissionOptionKind::AllowOnce,
        ),
        PermissionOption::new(
            PermissionOptionId::new("reject_once"),
            "Reject this action",
            PermissionOptionKind::RejectOnce,
        ),
    ]
}

/// Check if the user selected an allow option.
///
/// Uses the permission option kind, not the option ID string, to avoid
/// fragile substring matching (e.g., `disallow_once` would match `allow`).
#[must_use]
pub fn is_allow_outcome(outcome: &RequestPermissionOutcome, options: &[PermissionOption]) -> bool {
    match outcome {
        RequestPermissionOutcome::Selected(selected) => options.iter().any(|opt| {
            opt.option_id == selected.option_id
                && matches!(
                    opt.kind,
                    PermissionOptionKind::AllowOnce | PermissionOptionKind::AllowAlways
                )
        }),
        RequestPermissionOutcome::Cancelled | _ => false,
    }
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    fn permission_request() -> RequestPermissionRequest {
        RequestPermissionRequest::new(
            "session-1",
            agent_client_protocol::schema::ToolCallUpdate::new(
                "tool-1",
                agent_client_protocol::schema::ToolCallUpdateFields::new(),
            ),
            standard_permission_options(),
        )
    }

    #[test]
    fn standard_options_have_expected_ids() {
        let options = standard_permission_options();
        assert_eq!(options.len(), 2);
        assert_eq!(options[0].option_id.0.as_ref(), "allow_once");
        assert_eq!(options[1].option_id.0.as_ref(), "reject_once");
    }

    #[test]
    fn is_allow_outcome_detects_allow() {
        let options = standard_permission_options();

        let allow = RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
            PermissionOptionId::new("allow_once"),
        ));
        assert!(is_allow_outcome(&allow, &options));

        let reject = RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
            PermissionOptionId::new("reject_once"),
        ));
        assert!(!is_allow_outcome(&reject, &options));

        let cancelled = RequestPermissionOutcome::Cancelled;
        assert!(!is_allow_outcome(&cancelled, &options));
    }

    #[test]
    fn is_allow_outcome_ignores_misleading_ids() {
        let options = vec![PermissionOption::new(
            PermissionOptionId::new("disallow_once"),
            "Disallow this action",
            PermissionOptionKind::RejectOnce,
        )];

        let selected = RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
            PermissionOptionId::new("disallow_once"),
        ));
        assert!(!is_allow_outcome(&selected, &options));
    }

    #[test]
    fn stdin_gateway_selects_allow_option() {
        let request = permission_request();
        let mut input = Cursor::new(b"0\n");
        let mut output = Vec::new();

        let response =
            stdin_permission_gateway_from(&request, &mut input, &mut output).expect("permission");

        assert!(is_allow_outcome(&response.outcome, &request.options));
        assert!(
            String::from_utf8(output)
                .expect("utf8 output")
                .contains("Permission Request")
        );
    }

    #[test]
    fn stdin_gateway_invalid_choice_cancels() {
        let request = permission_request();
        let mut input = Cursor::new(b"not-a-choice\n");
        let mut output = Vec::new();

        let response =
            stdin_permission_gateway_from(&request, &mut input, &mut output).expect("permission");

        assert_eq!(response.outcome, RequestPermissionOutcome::Cancelled);
    }

    #[test]
    fn stdin_gateway_empty_options_cancels_without_prompting_choice_range() {
        let mut request = permission_request();
        request.options.clear();
        let mut input = Cursor::new(b"0\n");
        let mut output = Vec::new();

        let response =
            stdin_permission_gateway_from(&request, &mut input, &mut output).expect("permission");

        assert_eq!(response.outcome, RequestPermissionOutcome::Cancelled);
        assert!(
            String::from_utf8(output)
                .expect("utf8 output")
                .contains("No permission options supplied")
        );
    }
}
