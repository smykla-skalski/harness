use std::collections::BTreeMap;
use std::path::Path;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::json;
use tempfile::{TempDir, tempdir};
use tokio::sync::broadcast;

use super::{
    CodexControllerHandle, approvals::approval_from_request, handle::preferred_codex_project_dir,
    worker::upsert_pending_approval,
};
use crate::daemon::db::DaemonDb;
use crate::daemon::index::DiscoveredProject;
use crate::daemon::protocol::{
    CodexApprovalRequest, CodexRunMode, CodexRunRequest, CodexRunSnapshot, CodexRunStatus,
};
use crate::session::types::{SessionMetrics, SessionRole, SessionState, SessionStatus};

#[test]
fn start_run_rejects_empty_prompt_before_db_lookup() {
    let (sender, _) = broadcast::channel(8);
    let controller = CodexControllerHandle::new(sender, Arc::new(OnceLock::new()), false);
    let request = CodexRunRequest {
        actor: None,
        prompt: "   ".to_string(),
        mode: CodexRunMode::Report,
        role: SessionRole::Worker,
        fallback_role: None,
        capabilities: Vec::new(),
        name: None,
        persona: None,
        resume_thread_id: None,
        model: None,
        effort: None,
        allow_custom_model: false,
    };

    let error = controller
        .start_run("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc", &request)
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
        role: SessionRole::Worker,
        fallback_role: None,
        capabilities: Vec::new(),
        name: None,
        persona: None,
        resume_thread_id: None,
        model: Some("not-a-codex-model".to_string()),
        effort: None,
        allow_custom_model: false,
    };

    let error = controller
        .start_run("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc", &request)
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
        role: SessionRole::Worker,
        fallback_role: None,
        capabilities: Vec::new(),
        name: None,
        persona: None,
        resume_thread_id: None,
        model: Some("gpt-5.5".to_string()),
        effort: Some("extreme".to_string()),
        allow_custom_model: false,
    };

    let error = controller
        .start_run("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc", &request)
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
        role: SessionRole::Worker,
        fallback_role: None,
        capabilities: Vec::new(),
        name: None,
        persona: None,
        resume_thread_id: None,
        model: Some("gpt-6-private".to_string()),
        effort: Some("maximum".to_string()),
        allow_custom_model: true,
    };

    // Validation passes; the call will later fail at the websocket preflight
    // because no daemon is running, not at catalog validation.
    let error = controller
        .start_run("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc", &request)
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
        Path::new("/tmp/harness/sessions/eadbcb3e-6ef7-53d2-ad56-0347cb7189fc/workspace"),
        Some(Path::new("/tmp/harness/project")),
        Some(Path::new("/tmp/harness/repository")),
        Path::new("/tmp/harness/context"),
    );

    assert_eq!(
        resolved,
        "/tmp/harness/sessions/eadbcb3e-6ef7-53d2-ad56-0347cb7189fc/workspace"
    );
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

#[test]
fn stop_marks_stale_active_codex_run_cancelled() {
    let (controller, db, _tempdir) = controller_with_db();
    {
        let db = db.lock().expect("db lock");
        db.save_codex_run(&codex_run_snapshot(CodexRunStatus::Running))
            .expect("save codex run");
    }

    let stopped = controller.stop("codex-run-1").expect("stop codex run");

    assert_eq!(stopped.status, CodexRunStatus::Cancelled);
    assert!(stopped.pending_approvals.is_empty());
    assert!(
        stopped
            .events
            .iter()
            .any(|event| event.kind == "agent/stop"),
        "stop should record a lifecycle event"
    );
}

#[test]
fn list_runs_reconciles_stale_active_codex_run() {
    let (controller, db, _tempdir) = controller_with_db();
    {
        let db = db.lock().expect("db lock");
        db.save_codex_run(&codex_run_snapshot(CodexRunStatus::Running))
            .expect("save codex run");
    }

    let listed = controller
        .list_runs("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
        .expect("list codex runs")
        .runs;

    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].status, CodexRunStatus::Failed);
    assert_eq!(
        listed[0].error.as_deref(),
        Some("Codex turn is no longer attached to this daemon")
    );
    assert!(
        listed[0]
            .events
            .iter()
            .any(|event| event.kind == "agent/reconciled"),
        "stale reconciliation should be visible in the event stream"
    );
}

#[test]
fn transcript_includes_codex_prompt_and_final_message() {
    let (controller, db, _tempdir) = controller_with_db();
    let mut run = codex_run_snapshot(CodexRunStatus::Completed);
    run.final_message = Some("Done from Codex".into());
    {
        let db = db.lock().expect("db lock");
        db.save_codex_run(&run).expect("save codex run");
    }

    let transcript = controller
        .transcript("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
        .expect("codex transcript");

    assert!(
        transcript
            .entries
            .iter()
            .any(|entry| entry.kind == "user_prompt" && entry.summary == "Investigate"),
        "prompt should be exposed as transcript history"
    );
    assert!(
        transcript
            .entries
            .iter()
            .any(|entry| entry.kind == "assistant_text" && entry.summary == "Done from Codex"),
        "final response should be exposed as transcript history"
    );
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

fn controller_with_db() -> (CodexControllerHandle, Arc<Mutex<DaemonDb>>, TempDir) {
    let (sender, _) = broadcast::channel(8);
    let tempdir = tempdir().expect("temp dir");
    let db_path = tempdir.path().join("harness.db");
    let db = Arc::new(Mutex::new(DaemonDb::open(&db_path).expect("open db")));
    {
        let db_guard = db.lock().expect("db lock");
        db_guard
            .sync_project(&sample_project())
            .expect("sync project");
        db_guard
            .save_session_state("project-1", &sample_session_state())
            .expect("save session");
    }
    let db_slot = Arc::new(OnceLock::new());
    db_slot.set(db.clone()).expect("install db");
    (
        CodexControllerHandle::new(sender, db_slot, false),
        db,
        tempdir,
    )
}

fn sample_project() -> DiscoveredProject {
    DiscoveredProject {
        project_id: "project-1".into(),
        name: "harness".into(),
        project_dir: Some(PathBuf::from("/tmp/harness")),
        repository_root: Some(PathBuf::from("/tmp/harness")),
        checkout_id: "checkout-1".into(),
        checkout_name: "main".into(),
        context_root: PathBuf::from("/tmp/harness/.harness"),
        is_worktree: false,
        worktree_name: None,
    }
}

fn sample_session_state() -> SessionState {
    SessionState {
        schema_version: 3,
        state_version: 1,
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        project_name: "harness".into(),
        worktree_path: PathBuf::from("/tmp/harness/workspace"),
        shared_path: PathBuf::from("/tmp/harness/shared"),
        origin_path: PathBuf::from("/tmp/harness"),
        branch_ref: "harness/eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        title: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        context: "codex controller test".into(),
        status: SessionStatus::Active,
        policy: Default::default(),
        created_at: "2026-04-09T10:00:00Z".into(),
        updated_at: "2026-04-09T10:00:01Z".into(),
        agents: BTreeMap::new(),
        tasks: BTreeMap::new(),
        leader_id: None,
        archived_at: None,
        last_activity_at: Some("2026-04-09T10:00:01Z".into()),
        observe_id: None,
        pending_leader_transfer: None,
        external_origin: None,
        adopted_at: None,
        metrics: SessionMetrics::default(),
    }
}

fn codex_run_snapshot(status: CodexRunStatus) -> CodexRunSnapshot {
    CodexRunSnapshot {
        run_id: "codex-run-1".into(),
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        session_agent_id: Some("agent-1".into()),
        display_name: Some("Codex Worker".into()),
        project_dir: "/tmp/harness".into(),
        thread_id: Some("thread-1".into()),
        turn_id: Some("turn-1".into()),
        mode: CodexRunMode::WorkspaceWrite,
        status,
        prompt: "Investigate".into(),
        latest_summary: Some("Running".into()),
        final_message: None,
        error: None,
        pending_approvals: vec![codex_approval_request("approval-1", "request-1", "Approve")],
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: "2026-04-09T10:00:00Z".into(),
        updated_at: "2026-04-09T10:00:01Z".into(),
        model: Some("gpt-5.5".into()),
        effort: Some("high".into()),
    }
}
