use serde_json::{Value, json};

use crate::daemon::protocol::{CodexApprovalDecision, CodexApprovalRequest, CodexRunMode};

pub(super) fn thread_sandbox(mode: CodexRunMode) -> &'static str {
    match mode {
        CodexRunMode::Report | CodexRunMode::Approval => "read-only",
        CodexRunMode::WorkspaceWrite => "workspace-write",
    }
}

pub(super) fn approval_policy(mode: CodexRunMode) -> &'static str {
    match mode {
        CodexRunMode::Approval => "on-request",
        CodexRunMode::Report | CodexRunMode::WorkspaceWrite => "never",
    }
}

pub(super) fn turn_sandbox_policy(mode: CodexRunMode, project_dir: &str) -> Value {
    match mode {
        CodexRunMode::Report | CodexRunMode::Approval => json!({
            "type": "readOnly",
            "networkAccess": false,
            "access": { "type": "fullAccess" }
        }),
        CodexRunMode::WorkspaceWrite => json!({
            "type": "workspaceWrite",
            "networkAccess": false,
            "writableRoots": [project_dir],
            "readOnlyAccess": { "type": "fullAccess" }
        }),
    }
}

pub(super) fn mode_instructions(mode: CodexRunMode) -> &'static str {
    match mode {
        CodexRunMode::Report => {
            "You are running inside Harness report mode. Inspect the workspace and answer the user, but do not edit files, run mutating commands, or request approvals."
        }
        CodexRunMode::WorkspaceWrite => {
            "You are running inside Harness workspace-write mode. Keep changes scoped to the selected Harness project directory and do not request approvals."
        }
        CodexRunMode::Approval => {
            "You are running inside Harness approval mode. Request approval before commands or file changes that require it and wait for the Harness macOS app decision."
        }
    }
}

pub(super) fn approval_from_request(
    method: &str,
    request_id: String,
    params: &Value,
) -> Option<CodexApprovalRequest> {
    match method {
        "item/commandExecution/requestApproval" => {
            Some(command_approval_from_request(request_id, params))
        }
        "item/fileChange/requestApproval" => Some(file_approval_from_request(request_id, params)),
        "item/permissions/requestApproval" => {
            Some(permission_approval_from_request(request_id, params))
        }
        _ => None,
    }
}

pub(super) fn approval_result(method: &str, decision: CodexApprovalDecision) -> Value {
    match method {
        "item/permissions/requestApproval" => {
            let scope = if decision == CodexApprovalDecision::AcceptForSession {
                "session"
            } else {
                "turn"
            };
            json!({
                "permissions": {
                    "fileSystem": null,
                    "network": null
                },
                "scope": scope,
            })
        }
        _ => json!({
            "decision": app_server_approval_decision(decision),
        }),
    }
}

pub(super) fn trim_summary(value: &str) -> String {
    const LIMIT: usize = 512;
    let trimmed = value.trim();
    if trimmed.len() <= LIMIT {
        return trimmed.to_string();
    }
    trimmed
        .char_indices()
        .take_while(|(index, _)| *index < LIMIT)
        .map(|(_, ch)| ch)
        .collect()
}

struct ApprovalTemplate<'a> {
    kind: &'a str,
    title: &'a str,
    default_detail: &'a str,
    cwd: Option<String>,
    command: Option<String>,
    file_path: Option<String>,
}

fn command_approval_from_request(request_id: String, params: &Value) -> CodexApprovalRequest {
    let approval_id = params
        .get("itemId")
        .and_then(Value::as_str)
        .or_else(|| params.get("approvalId").and_then(Value::as_str))
        .unwrap_or(request_id.as_str())
        .to_string();
    approval_request(
        request_id,
        approval_id,
        params,
        ApprovalTemplate {
            kind: "command",
            title: "Command approval requested",
            default_detail: "Codex wants to run a command.",
            cwd: string_param(params, "cwd"),
            command: string_param(params, "command"),
            file_path: None,
        },
    )
}

fn file_approval_from_request(request_id: String, params: &Value) -> CodexApprovalRequest {
    let approval_id = item_or_request_id(params, &request_id);
    approval_request(
        request_id,
        approval_id,
        params,
        ApprovalTemplate {
            kind: "file_change",
            title: "File change approval requested",
            default_detail: "Codex wants to change files.",
            cwd: None,
            command: None,
            file_path: string_param(params, "grantRoot"),
        },
    )
}

fn permission_approval_from_request(request_id: String, params: &Value) -> CodexApprovalRequest {
    let approval_id = item_or_request_id(params, &request_id);
    approval_request(
        request_id,
        approval_id,
        params,
        ApprovalTemplate {
            kind: "permissions",
            title: "Permission approval requested",
            default_detail: "Codex wants additional permissions.",
            cwd: None,
            command: None,
            file_path: None,
        },
    )
}

fn approval_request(
    request_id: String,
    approval_id: String,
    params: &Value,
    template: ApprovalTemplate<'_>,
) -> CodexApprovalRequest {
    CodexApprovalRequest {
        approval_id,
        request_id,
        kind: template.kind.to_string(),
        title: template.title.to_string(),
        detail: params
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or(template.default_detail)
            .to_string(),
        thread_id: string_param(params, "threadId"),
        turn_id: string_param(params, "turnId"),
        item_id: string_param(params, "itemId"),
        cwd: template.cwd,
        command: template.command,
        file_path: template.file_path,
    }
}

fn item_or_request_id(params: &Value, request_id: &str) -> String {
    params
        .get("itemId")
        .and_then(Value::as_str)
        .unwrap_or(request_id)
        .to_string()
}

fn string_param(params: &Value, key: &str) -> Option<String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(ToString::to_string)
}

fn app_server_approval_decision(decision: CodexApprovalDecision) -> &'static str {
    match decision {
        CodexApprovalDecision::Accept => "accept",
        CodexApprovalDecision::AcceptForSession => "acceptForSession",
        CodexApprovalDecision::Decline => "decline",
        CodexApprovalDecision::Cancel => "cancel",
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{approval_policy, thread_sandbox, turn_sandbox_policy};
    use crate::daemon::protocol::CodexRunMode;

    #[test]
    fn approval_mode_uses_read_only_thread_sandbox() {
        assert_eq!(thread_sandbox(CodexRunMode::Approval), "read-only");
    }

    #[test]
    fn approval_mode_keeps_on_request_policy_and_read_only_turn_sandbox() {
        assert_eq!(approval_policy(CodexRunMode::Approval), "on-request");
        assert_eq!(
            turn_sandbox_policy(CodexRunMode::Approval, "/tmp/project"),
            json!({
                "type": "readOnly",
                "networkAccess": false,
                "access": { "type": "fullAccess" }
            })
        );
    }
}
