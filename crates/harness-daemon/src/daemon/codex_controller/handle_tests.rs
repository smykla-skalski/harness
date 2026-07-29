use super::*;
use crate::daemon::protocol::CodexRunMode;
use crate::session::types::SessionRole;

#[test]
fn queued_run_snapshot_copies_binding_and_normalizes_optional_values() {
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
        task_id: Some("task-1".to_string()),
        board_item_id: Some("board-item-1".to_string()),
        workflow_execution_id: Some("workflow-1".to_string()),
        model: Some("  ".to_string()),
        effort: Some(" high ".to_string()),
        allow_custom_model: false,
    };

    let snapshot = queued_run_snapshot(
        "session-1",
        &request,
        "run-1".to_string(),
        "/tmp/project".to_string(),
        "investigate",
        Some("agent-1".to_string()),
        "Codex".to_string(),
    );

    assert_eq!(snapshot.model, None);
    assert_eq!(snapshot.effort.as_deref(), Some("high"));
    assert_eq!(snapshot.prompt, "investigate");
    let value = serde_json::to_value(snapshot).expect("serialize queued snapshot");
    assert_eq!(value["task_id"], "task-1");
    assert_eq!(value["board_item_id"], "board-item-1");
    assert_eq!(value["workflow_execution_id"], "workflow-1");
}

/// The prompt a run is persisted with comes from the request, so whatever a
/// render site produced is what the run row -- and everything recovering from
/// it -- reports the agent ran with.
#[test]
fn the_persisted_prompt_is_the_one_the_request_carried() {
    let request = CodexRunRequest {
        actor: None,
        prompt: "  Work on task-board item 'Ship it'.  ".to_string(),
        mode: CodexRunMode::Report,
        role: SessionRole::Worker,
        fallback_role: None,
        capabilities: Vec::new(),
        name: None,
        persona: None,
        resume_thread_id: None,
        task_id: None,
        board_item_id: None,
        workflow_execution_id: None,
        model: None,
        effort: None,
        allow_custom_model: false,
    };

    let prompt = validate_run_request(&request).expect("validate run request");
    let snapshot = queued_run_snapshot(
        "session-1",
        &request,
        "run-1".to_string(),
        "/tmp/project".to_string(),
        prompt,
        None,
        "Codex".to_string(),
    );

    assert_eq!(snapshot.prompt, request.prompt.trim());
}
