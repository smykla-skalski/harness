use super::HOST_ID;
use crate::daemon::db::Connection;
use rusqlite::params;

pub(in super::super) fn strict_request(
    assignment_id: &str,
    execution_id: &str,
    epoch: i64,
    digest: &str,
) -> String {
    serde_json::json!({
        "schema_version": 1,
        "binding": {
            "assignment_id": assignment_id,
            "execution_id": execution_id,
            "phase": "implementation",
            "workflow_kind": "default_task",
            "action_key": "implementation:1",
            "attempt": 1,
            "idempotency_key": format!("idempotency-{assignment_id}"),
            "host_id": HOST_ID,
            "host_instance_id": "instance-a",
            "fencing_epoch": epoch,
            "configuration_revision": 7,
            "execution_record_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "repository": "acme/widgets",
            "base_revision": "1111111111111111111111111111111111111111"
        },
        "lease_seconds": 300,
        "deadline_at": "2026-07-19T10:00:00Z",
        "launch": {
            "schema_version": 1,
            "runtime": "codex",
            "actor": "harness-app",
            "prompt": "Implement the approved plan.",
            "mode": "workspace_write",
            "role": "leader",
            "fallback_role": "worker",
            "capabilities": ["task-board", "task-board:workflow:write"],
            "display_name": "Task Board Implementation: Widgets",
            "task_id": "task-a",
            "board_item_id": "item-a",
            "workflow_execution_id": execution_id,
            "allow_custom_model": false
        },
        "source": {
            "kind": "repository",
            "schema_version": 1,
            "repository": "acme/widgets",
            "selector": {"kind": "exact_revision"},
            "revision": "1111111111111111111111111111111111111111"
        },
        "artifacts": {"entries": []},
        "request_sha256": digest,
    })
    .to_string()
}

pub(in super::super) fn insert_strict_assignment(
    conn: &Connection,
    assignment_id: &str,
    epoch: i64,
    request_json: &str,
) -> rusqlite::Result<usize> {
    let request_sha256 = serde_json::from_str::<serde_json::Value>(request_json)
        .expect("parse request")
        .get("request_sha256")
        .and_then(serde_json::Value::as_str)
        .expect("request digest")
        .to_string();
    conn.execute(
        "INSERT INTO task_board_remote_assignments (
             assignment_id, execution_id, phase, action_key, attempt, idempotency_key,
             host_id, target_host_instance_id, claimed_host_instance_id, fencing_epoch,
             configuration_revision, execution_record_sha256, request_sha256, request_json,
             authenticated_principal, state, legacy_migrated, offered_at, lease_expires_at,
             deadline_at, updated_at
         ) VALUES (
             ?1, 'execution-a', 'implementation', 'implementation:1', 1, ?2, ?3, 'instance-a',
             NULL, ?4, 7,
             'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
             ?5, ?6, 'executor:executor-a', 'offered', 0,
             '2026-07-19T09:00:00Z', '2026-07-19T09:05:00Z',
             '2026-07-19T10:00:00Z', '2026-07-19T09:00:00Z'
         )",
        params![
            assignment_id,
            format!("idempotency-{assignment_id}"),
            HOST_ID,
            epoch,
            request_sha256,
            request_json,
        ],
    )
}
