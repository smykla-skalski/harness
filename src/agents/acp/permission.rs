//! Permission gateway modes for ACP `session/request_permission`.
//!
//! No trait, no abstraction: the gateway is a direct `match` at the call site.
//! `DaemonBridge` arm is wired in Chunk 7; `Recording` arm in Chunk 10.

use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::mpsc::SyncSender;
use std::time::Duration;

use agent_client_protocol::schema::{
    PermissionOption, PermissionOptionId, PermissionOptionKind, RequestPermissionOutcome,
    RequestPermissionRequest, RequestPermissionResponse, SelectedPermissionOutcome,
};
use tokio::sync::mpsc::Sender;

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
