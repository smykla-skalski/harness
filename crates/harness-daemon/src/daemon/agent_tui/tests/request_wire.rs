use crate::daemon::agent_tui::AgentTuiStartRequest;
use crate::session::types::SessionRole;

use super::super::{DEFAULT_COLS, DEFAULT_ROWS};

#[test]
fn agent_tui_start_request_task_binding_fields_round_trip() {
    let request = AgentTuiStartRequest {
        runtime: "codex".to_string(),
        role: SessionRole::Worker,
        fallback_role: None,
        capabilities: Vec::new(),
        name: None,
        prompt: None,
        project_dir: None,
        argv: Vec::new(),
        rows: DEFAULT_ROWS,
        cols: DEFAULT_COLS,
        persona: None,
        task_id: Some("task-1".to_string()),
        board_item_id: Some("board-item-1".to_string()),
        workflow_execution_id: Some("workflow-1".to_string()),
        model: None,
        effort: None,
        allow_custom_model: false,
    };

    let value = serde_json::to_value(&request).expect("serialize request");
    assert_eq!(value["task_id"], "task-1");
    assert_eq!(value["board_item_id"], "board-item-1");
    assert_eq!(value["workflow_execution_id"], "workflow-1");

    let decoded: AgentTuiStartRequest = serde_json::from_value(value).expect("decode request");
    assert_eq!(decoded.task_id.as_deref(), Some("task-1"));
    assert_eq!(decoded.board_item_id.as_deref(), Some("board-item-1"));
    assert_eq!(decoded.workflow_execution_id.as_deref(), Some("workflow-1"));

    let legacy: AgentTuiStartRequest = serde_json::from_value(serde_json::json!({
        "runtime": "codex"
    }))
    .expect("decode legacy request");
    assert!(legacy.task_id.is_none());
    assert!(legacy.board_item_id.is_none());
    assert!(legacy.workflow_execution_id.is_none());
}
