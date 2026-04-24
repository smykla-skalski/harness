use std::path::Path;
use std::sync::{Arc, OnceLock};

use serde_json::json;
use tokio::sync::broadcast;

use super::{
    CodexControllerHandle, approvals::approval_from_request, handle::preferred_codex_project_dir,
    worker::upsert_pending_approval,
};
use crate::daemon::protocol::{CodexApprovalRequest, CodexRunMode, CodexRunRequest};

#[test]
fn start_run_rejects_empty_prompt_before_db_lookup() {
    let (sender, _) = broadcast::channel(8);
    let controller = CodexControllerHandle::new(sender, Arc::new(OnceLock::new()), false);
    let request = CodexRunRequest {
        actor: None,
        prompt: "   ".to_string(),
        mode: CodexRunMode::Report,
        resume_thread_id: None,
        model: None,
        effort: None,
        allow_custom_model: false,
    };

    let error = controller
        .start_run("sess-1", &request)
        .expect_err("empty prompt should be rejected");
    assert!(
        error.to_string().contains("codex prompt cannot be empty"),
        "unexpected error: {error}"
    );
}

#[test]
fn start_run_rejects_unknown_model_for_codex() {
    let (sender, _) = broadcast::channel(8);
    let controller = CodexControllerHandle::new(sender, Arc::new(OnceLock::new()), false);
    let request = CodexRunRequest {
        actor: None,
        prompt: "investigate".to_string(),
        mode: CodexRunMode::Report,
        resume_thread_id: None,
        model: Some("not-a-codex-model".to_string()),
        effort: None,
        allow_custom_model: false,
    };

    let error = controller
        .start_run("sess-1", &request)
        .expect_err("invalid model should be rejected");
    let message = error.to_string();
    assert!(
        message.contains("not-a-codex-model"),
        "unexpected error: {message}"
    );
    assert!(
        message.contains("gpt-5.5"),
        "error should list valid codex models: {message}"
    );
}

#[test]
fn start_run_rejects_unknown_effort_value() {
    let (sender, _) = broadcast::channel(8);
    let controller = CodexControllerHandle::new(sender, Arc::new(OnceLock::new()), false);
    let request = CodexRunRequest {
        actor: None,
        prompt: "investigate".to_string(),
        mode: CodexRunMode::Report,
        resume_thread_id: None,
        model: Some("gpt-5.5".to_string()),
        effort: Some("extreme".to_string()),
        allow_custom_model: false,
    };

    let error = controller
        .start_run("sess-1", &request)
        .expect_err("unknown effort should be rejected");
    let message = error.to_string();
    assert!(message.contains("extreme"), "unexpected error: {message}");
}

#[test]
fn start_run_accepts_custom_model_and_effort_when_opt_in() {
    let (sender, _) = broadcast::channel(8);
    let controller = CodexControllerHandle::new(sender, Arc::new(OnceLock::new()), false);
    let request = CodexRunRequest {
        actor: None,
        prompt: "explore".to_string(),
        mode: CodexRunMode::Report,
        resume_thread_id: None,
        model: Some("gpt-6-private".to_string()),
        effort: Some("maximum".to_string()),
        allow_custom_model: true,
    };

    // Validation passes; the call will later fail at the websocket preflight
    // because no daemon is running, not at catalog validation.
    let error = controller
        .start_run("sess-1", &request)
        .expect_err("preflight fails without daemon");
    let message = error.to_string();
    assert!(
        !message.contains("gpt-6-private"),
        "custom model should not show in validation error: {message}"
    );
    assert!(
        !message.contains("maximum"),
        "custom effort should not show in validation error: {message}"
    );
}

#[test]
fn preferred_codex_project_dir_uses_session_worktree_when_present() {
    let resolved = preferred_codex_project_dir(
        Path::new("/tmp/harness/sessions/sess-1/workspace"),
        Some(Path::new("/tmp/harness/project")),
        Some(Path::new("/tmp/harness/repository")),
        Path::new("/tmp/harness/context"),
    );

    assert_eq!(resolved, "/tmp/harness/sessions/sess-1/workspace");
}

#[test]
fn preferred_codex_project_dir_falls_back_when_worktree_is_empty() {
    let resolved = preferred_codex_project_dir(
        Path::new(""),
        Some(Path::new("/tmp/harness/project")),
        Some(Path::new("/tmp/harness/repository")),
        Path::new("/tmp/harness/context"),
    );

    assert_eq!(resolved, "/tmp/harness/project");
}

#[test]
fn command_approval_uses_item_id_as_stable_ui_key() {
    let first = approval_from_request(
        "item/commandExecution/requestApproval",
        "request-1".to_string(),
        &json!({
            "approvalId": "approval-1",
            "itemId": "item-1",
            "cwd": "/tmp/harness",
            "command": "rtk touch approved.txt",
        }),
    )
    .expect("command approval should be parsed");
    let second = approval_from_request(
        "item/commandExecution/requestApproval",
        "request-2".to_string(),
        &json!({
            "approvalId": "approval-2",
            "itemId": "item-1",
            "cwd": "/tmp/harness",
            "command": "rtk touch approved.txt",
        }),
    )
    .expect("command approval should be parsed");

    assert_eq!(first.approval_id, "item-1");
    assert_eq!(second.approval_id, "item-1");
}

#[test]
fn upsert_pending_approval_replaces_existing_visible_row() {
    let mut approvals = vec![codex_approval_request(
        "item-1",
        "request-1",
        "first command detail",
    )];

    upsert_pending_approval(
        &mut approvals,
        codex_approval_request("item-1", "request-2", "updated command detail"),
    );

    assert_eq!(approvals.len(), 1);
    assert_eq!(approvals[0].request_id, "request-2");
    assert_eq!(approvals[0].detail, "updated command detail");
}

fn codex_approval_request(
    approval_id: &str,
    request_id: &str,
    detail: &str,
) -> CodexApprovalRequest {
    CodexApprovalRequest {
        approval_id: approval_id.to_string(),
        request_id: request_id.to_string(),
        kind: "command".to_string(),
        title: "Command approval requested".to_string(),
        detail: detail.to_string(),
        thread_id: Some("thread-1".to_string()),
        turn_id: Some("turn-1".to_string()),
        item_id: Some(approval_id.to_string()),
        cwd: Some("/tmp/harness".to_string()),
        command: Some("rtk touch approved.txt".to_string()),
        file_path: None,
    }
}
