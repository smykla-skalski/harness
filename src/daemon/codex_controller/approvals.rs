use std::path::Path;

use serde_json::{Map, Value, json};

use crate::daemon::protocol::{CodexApprovalDecision, CodexApprovalRequest, CodexRunMode};

pub(super) const WORKSPACE_PERMISSION_PROFILE: &str = "harness-workspace-write";
const READ_ONLY_PERMISSION_PROFILE: &str = ":read-only";

pub(super) fn permission_profile(mode: CodexRunMode) -> &'static str {
    match mode {
        CodexRunMode::Report | CodexRunMode::Approval => READ_ONLY_PERMISSION_PROFILE,
        CodexRunMode::WorkspaceWrite => WORKSPACE_PERMISSION_PROFILE,
    }
}

pub(super) fn approval_policy(mode: CodexRunMode) -> &'static str {
    match mode {
        CodexRunMode::Approval => "on-request",
        CodexRunMode::Report | CodexRunMode::WorkspaceWrite => "never",
    }
}

pub(super) fn runtime_workspace_roots(project_dir: &str) -> Vec<String> {
    let project = Path::new(project_dir)
        .canonicalize()
        .unwrap_or_else(|_| Path::new(project_dir).to_path_buf());
    let mut roots = vec![project.display().to_string()];
    let Ok(repository) = gix::discover(&project) else {
        return roots;
    };
    let common_dir = repository
        .common_dir()
        .canonicalize()
        .unwrap_or_else(|_| repository.common_dir().to_path_buf());
    if !common_dir.starts_with(&project) {
        roots.push(common_dir.display().to_string());
    }
    roots
}

pub(super) fn workspace_permission_config(project_dir: &str) -> Value {
    let signing_socket = std::env::var_os("SSH_AUTH_SOCK");
    workspace_permission_config_with_signing_socket(
        project_dir,
        signing_socket.as_deref().map(Path::new),
    )
}

fn workspace_permission_config_with_signing_socket(
    project_dir: &str,
    signing_socket: Option<&Path>,
) -> Value {
    let mut filesystem = Map::new();
    for path in workspace_git_metadata_roots(project_dir) {
        filesystem.insert(path, Value::String("write".to_string()));
    }
    let mut profile = json!({
        "extends": ":workspace",
        "filesystem": filesystem
    });
    if let Some(signing_socket) = signing_socket.filter(|path| path.is_absolute()) {
        profile["network"] = json!({
            "enabled": true,
            "unix_sockets": {
                (signing_socket.display().to_string()): "allow"
            }
        });
    }
    json!({
        "permissions": {
            (WORKSPACE_PERMISSION_PROFILE): profile
        }
    })
}

fn workspace_git_metadata_roots(project_dir: &str) -> Vec<String> {
    let project = Path::new(project_dir)
        .canonicalize()
        .unwrap_or_else(|_| Path::new(project_dir).to_path_buf());
    let Ok(repository) = gix::discover(&project) else {
        return Vec::new();
    };
    let mut roots = Vec::new();
    for path in [repository.git_dir(), repository.common_dir()] {
        let path = path
            .canonicalize()
            .unwrap_or_else(|_| path.to_path_buf())
            .display()
            .to_string();
        if !roots.contains(&path) {
            roots.push(path);
        }
    }
    roots
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

pub(super) fn approval_result(
    method: &str,
    decision: CodexApprovalDecision,
    params: &Value,
) -> Value {
    match method {
        "item/permissions/requestApproval" => permission_approval_result(decision, params),
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

pub(super) fn upsert_pending_approval(
    approvals: &mut Vec<CodexApprovalRequest>,
    approval: CodexApprovalRequest,
) {
    if let Some(existing) = approvals
        .iter_mut()
        .find(|candidate| candidate.approval_id == approval.approval_id)
    {
        *existing = approval;
    } else {
        approvals.push(approval);
    }
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
        .get("approvalId")
        .and_then(Value::as_str)
        .or_else(|| params.get("itemId").and_then(Value::as_str))
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

fn permission_approval_result(decision: CodexApprovalDecision, params: &Value) -> Value {
    let (permissions, scope) = match decision {
        CodexApprovalDecision::Accept => (
            params
                .get("permissions")
                .cloned()
                .unwrap_or_else(|| json!({})),
            "turn",
        ),
        CodexApprovalDecision::AcceptForSession => (
            params
                .get("permissions")
                .cloned()
                .unwrap_or_else(|| json!({})),
            "session",
        ),
        CodexApprovalDecision::Decline | CodexApprovalDecision::Cancel => (json!({}), "turn"),
    };
    json!({
        "permissions": permissions,
        "scope": scope,
    })
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use tempfile::tempdir;

    use super::{
        approval_policy, approval_result, permission_profile, runtime_workspace_roots,
        workspace_permission_config_with_signing_socket, WORKSPACE_PERMISSION_PROFILE,
    };
    use crate::daemon::protocol::{CodexApprovalDecision, CodexRunMode};
    use crate::git::mutation::create_linked_worktree;

    #[test]
    fn report_and_approval_modes_use_modern_read_only_profile() {
        assert_eq!(permission_profile(CodexRunMode::Report), ":read-only");
        assert_eq!(permission_profile(CodexRunMode::Approval), ":read-only");
    }

    #[test]
    fn approval_mode_keeps_on_request_policy() {
        assert_eq!(approval_policy(CodexRunMode::Approval), "on-request");
        assert_eq!(
            permission_profile(CodexRunMode::WorkspaceWrite),
            WORKSPACE_PERMISSION_PROFILE
        );
    }

    #[test]
    fn linked_worktree_runtime_roots_include_common_git_metadata() {
        let root = tempdir().expect("tempdir");
        let origin = root.path().join("origin");
        let worker = root.path().join("worker");
        harness_testkit::init_git_repo_with_seed(&origin);
        let head = harness_testkit::git_head_sha(&origin, "HEAD");
        create_linked_worktree(
            &origin,
            "worker",
            &worker,
            "harness/worker",
            &head,
        )
        .expect("create linked worktree");

        assert_eq!(
            runtime_workspace_roots(worker.to_str().expect("utf8 worker")),
            vec![
                worker.canonicalize().expect("canonical worker").display().to_string(),
                origin
                    .join(".git")
                    .canonicalize()
                    .expect("canonical common git dir")
                    .display()
                    .to_string(),
            ]
        );
    }

    #[test]
    fn linked_worktree_permission_profile_explicitly_writes_git_metadata() {
        let root = tempdir().expect("tempdir");
        let origin = root.path().join("origin");
        let worker = root.path().join("worker");
        harness_testkit::init_git_repo_with_seed(&origin);
        let head = harness_testkit::git_head_sha(&origin, "HEAD");
        create_linked_worktree(&origin, "worker", &worker, "harness/worker", &head)
            .expect("create linked worktree");

        let git_dir = origin
            .join(".git/worktrees/worker")
            .canonicalize()
            .expect("canonical linked git dir")
            .display()
            .to_string();
        let common_dir = origin
            .join(".git")
            .canonicalize()
            .expect("canonical common git dir")
            .display()
            .to_string();
        assert_eq!(
            workspace_permission_config_with_signing_socket(
                worker.to_str().expect("utf8 worker"),
                None,
            ),
            json!({
                "permissions": {
                    (WORKSPACE_PERMISSION_PROFILE): {
                        "extends": ":workspace",
                        "filesystem": {
                            (git_dir): "write",
                            (common_dir): "write"
                        }
                    }
                }
            })
        );
    }

    #[test]
    fn workspace_permission_profile_starts_proxy_for_signing_socket() {
        let root = tempdir().expect("tempdir");
        let origin = root.path().join("origin");
        harness_testkit::init_git_repo_with_seed(&origin);
        let socket = root.path().join("agent.sock");

        let config = workspace_permission_config_with_signing_socket(
            origin.to_str().expect("utf8 origin"),
            Some(&socket),
        );

        assert_eq!(
            config["permissions"][WORKSPACE_PERMISSION_PROFILE]["network"]["unix_sockets"]
                [&socket.display().to_string()],
            json!("allow")
        );
        assert_eq!(
            config["permissions"][WORKSPACE_PERMISSION_PROFILE]["network"]["enabled"],
            json!(true)
        );
        assert!(
            config["permissions"][WORKSPACE_PERMISSION_PROFILE]["network"]
                .get("domains")
                .is_none()
        );
    }

    #[test]
    fn permissions_accept_grants_requested_subset_for_turn_or_session() {
        let params = json!({
            "permissions": {
                "fileSystem": {
                    "write": ["/tmp/project"]
                },
                "network": {
                    "enabled": true
                }
            }
        });

        assert_eq!(
            approval_result(
                "item/permissions/requestApproval",
                CodexApprovalDecision::Accept,
                &params
            ),
            json!({
                "permissions": params["permissions"],
                "scope": "turn",
            })
        );
        assert_eq!(
            approval_result(
                "item/permissions/requestApproval",
                CodexApprovalDecision::AcceptForSession,
                &params
            ),
            json!({
                "permissions": params["permissions"],
                "scope": "session",
            })
        );
    }

    #[test]
    fn permissions_decline_and_cancel_grant_empty_subset() {
        let params = json!({
            "permissions": {
                "fileSystem": {
                    "write": ["/tmp/project"]
                }
            }
        });

        for decision in [
            CodexApprovalDecision::Decline,
            CodexApprovalDecision::Cancel,
        ] {
            assert_eq!(
                approval_result("item/permissions/requestApproval", decision, &params),
                json!({
                    "permissions": {},
                    "scope": "turn",
                })
            );
        }
    }
}
