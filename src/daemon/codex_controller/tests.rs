use serde_json::json;
use std::path::Path;

use super::{
    approvals::{approval_from_request, upsert_pending_approval},
    handle::{preferred_codex_project_dir, record_snapshot_event},
};
use crate::daemon::protocol::CodexRunStatus;
use crate::session::types::AgentStatus;

mod golden_path;
mod request_validation;
mod test_support;

use self::test_support::{
    codex_approval_request, codex_run_snapshot, controller_with_db, controller_with_session_state,
    sample_session_state_with_codex_agent,
};

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
fn command_approval_uses_callback_approval_id_when_present() {
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

    assert_eq!(first.approval_id, "approval-1");
    assert_eq!(second.approval_id, "approval-2");
    assert_eq!(first.item_id.as_deref(), Some("item-1"));
    assert_eq!(second.item_id.as_deref(), Some("item-1"));
}

#[test]
fn command_approval_falls_back_to_item_id_without_callback_id() {
    let approval = approval_from_request(
        "item/commandExecution/requestApproval",
        "request-1".to_string(),
        &json!({
            "itemId": "item-1",
            "cwd": "/tmp/harness",
            "command": "rtk touch approved.txt",
        }),
    )
    .expect("command approval should be parsed");

    assert_eq!(approval.approval_id, "item-1");
    assert_eq!(approval.item_id.as_deref(), Some("item-1"));
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
fn run_reconciles_stale_active_codex_run() {
    let (controller, db, _tempdir) = controller_with_db();
    {
        let db = db.lock().expect("db lock");
        db.save_codex_run(&codex_run_snapshot(CodexRunStatus::Running))
            .expect("save codex run");
    }

    let run = controller.run("codex-run-1").expect("load codex run");

    assert_eq!(run.status, CodexRunStatus::Failed);
    assert_eq!(
        run.error.as_deref(),
        Some("Codex turn is no longer attached to this daemon")
    );
    let persisted = db
        .lock()
        .expect("db lock")
        .codex_run("codex-run-1")
        .expect("load persisted run")
        .expect("persisted run");
    assert_eq!(persisted.status, CodexRunStatus::Failed);
}

#[test]
fn follow_up_attach_failure_marks_run_failed() {
    let (controller, db, _tempdir) = controller_with_db();
    let mut run = codex_run_snapshot(CodexRunStatus::Completed);
    run.thread_id = Some("thread-1".into());
    {
        let db = db.lock().expect("db lock");
        db.save_codex_run(&run).expect("save codex run");
    }
    controller.poison_active_runs_for_test();

    let error = controller
        .steer(
            "codex-run-1",
            &crate::daemon::protocol::CodexSteerRequest {
                prompt: "follow up".into(),
            },
        )
        .expect_err("active run attach should fail");

    assert!(
        error.to_string().contains("codex active run lock poisoned"),
        "unexpected error: {error}"
    );
    let persisted = db
        .lock()
        .expect("db lock")
        .codex_run("codex-run-1")
        .expect("load persisted run")
        .expect("persisted run");
    assert_eq!(persisted.status, CodexRunStatus::Failed);
    assert_eq!(
        persisted.latest_summary.as_deref(),
        Some("Codex worker could not attach follow-up turn to daemon")
    );
}

#[test]
fn list_runs_repairs_disconnected_codex_orchestration_agent() {
    let (controller, db, _tempdir) = controller_with_session_state(
        sample_session_state_with_codex_agent(AgentStatus::disconnected_unknown()),
    );
    {
        let db = db.lock().expect("db lock");
        db.save_codex_run(&codex_run_snapshot(CodexRunStatus::Completed))
            .expect("save codex run");
    }

    let listed = controller
        .list_runs("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
        .expect("list codex runs")
        .runs;

    assert_eq!(listed.len(), 1);
    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
        .expect("load session")
        .expect("session");
    let agent = state.agents.get("agent-1").expect("codex agent");
    assert_eq!(agent.status, AgentStatus::Idle);
    assert_eq!(state.metrics.agent_count, 1);
    assert_eq!(state.metrics.idle_agent_count, 1);
}

#[test]
fn run_repairs_disconnected_codex_orchestration_agent() {
    let (controller, db, _tempdir) = controller_with_session_state(
        sample_session_state_with_codex_agent(AgentStatus::disconnected_unknown()),
    );
    {
        let db = db.lock().expect("db lock");
        db.save_codex_run(&codex_run_snapshot(CodexRunStatus::Completed))
            .expect("save codex run");
    }

    let run = controller.run("codex-run-1").expect("load codex run");

    assert_eq!(run.status, CodexRunStatus::Completed);
    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
        .expect("load session")
        .expect("session");
    let agent = state.agents.get("agent-1").expect("codex agent");
    assert_eq!(agent.status, AgentStatus::Idle);
    assert_eq!(state.metrics.agent_count, 1);
    assert_eq!(state.metrics.idle_agent_count, 1);
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

#[test]
fn transcript_deduplicates_final_message_from_completed_item_event() {
    let (controller, db, _tempdir) = controller_with_db();
    let mut run = codex_run_snapshot(CodexRunStatus::Completed);
    run.final_message = Some("Done from Codex".into());
    record_snapshot_event(
        &mut run,
        "item/completed",
        "item/completed: agentMessage".to_string(),
        &json!({
            "item": {
                "type": "agentMessage",
                "text": "Done from Codex",
                "phase": "final_answer"
            }
        }),
    );
    {
        let db = db.lock().expect("db lock");
        db.save_codex_run(&run).expect("save codex run");
    }

    let transcript = controller
        .transcript("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
        .expect("codex transcript");

    let assistant_entries = transcript
        .entries
        .iter()
        .filter(|entry| entry.kind == "assistant_text" && entry.summary == "Done from Codex")
        .count();
    assert_eq!(assistant_entries, 1);
}
