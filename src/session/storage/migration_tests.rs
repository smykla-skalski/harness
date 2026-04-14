use serde_json::json;

use crate::session::types::CURRENT_VERSION;

use super::migrations::{
    migrate_v1_to_v2, migrate_v2_to_v3, migrate_v3_to_v4, migrate_v4_to_v5, migrate_v5_to_v6,
};
use super::registry::{merge_project_origin, ProjectOriginRecord};

#[test]
fn migrate_v1_and_v2_stamp_expected_schema_versions() {
    let v1 = json!({
        "schema_version": 1,
        "session_id": "sess-1",
        "context": "test",
        "status": "active",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "agents": {},
        "tasks": {},
    });
    let migrated_v2 = migrate_v1_to_v2(v1).expect("migrate v1");
    assert_eq!(migrated_v2["schema_version"], json!(2));

    let v2 = json!({
        "schema_version": 2,
        "session_id": "sess-1",
        "context": "test",
        "status": "active",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "agents": {},
        "tasks": {},
    });
    let migrated_v3 = migrate_v2_to_v3(v2).expect("migrate v2");
    assert_eq!(migrated_v3["schema_version"], json!(3));
}

#[test]
fn migrate_v3_to_v4_backfills_title_from_context() {
    let migrated = migrate_v3_to_v4(json!({
        "schema_version": 3,
        "state_version": 2,
        "session_id": "sess-1",
        "context": "session goal",
        "status": "active",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "agents": {},
        "tasks": {},
        "leader_id": null,
        "archived_at": null,
        "last_activity_at": null,
        "observe_id": null,
        "pending_leader_transfer": null,
        "metrics": {
            "agent_count": 0,
            "active_agent_count": 0,
            "open_task_count": 0,
            "in_progress_task_count": 0,
            "blocked_task_count": 0,
            "completed_task_count": 0
        }
    }))
    .expect("migrate v3");

    assert_eq!(migrated["schema_version"], json!(4));
    assert_eq!(migrated["title"], json!("session goal"));
}

#[test]
fn migrate_v4_to_v5_stamps_current_schema() {
    let migrated = migrate_v4_to_v5(json!({
        "schema_version": 4,
        "state_version": 2,
        "session_id": "sess-1",
        "title": "session title",
        "context": "session goal",
        "status": "active",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "agents": {},
        "tasks": {},
        "leader_id": null,
        "archived_at": null,
        "last_activity_at": null,
        "observe_id": null,
        "pending_leader_transfer": null,
        "metrics": {
            "agent_count": 0,
            "active_agent_count": 0,
            "open_task_count": 0,
            "in_progress_task_count": 0,
            "blocked_task_count": 0,
            "completed_task_count": 0
        }
    }))
    .expect("migrate v4");

    assert_eq!(migrated["schema_version"], json!(5));
    assert_eq!(migrated["title"], json!("session title"));
}

#[test]
fn migrate_v5_to_v6_stamps_current_schema() {
    let migrated = migrate_v5_to_v6(json!({
        "schema_version": 5,
        "state_version": 3,
        "session_id": "sess-1",
        "title": "session title",
        "context": "session goal",
        "status": "active",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "agents": {},
        "tasks": {},
        "leader_id": null,
        "archived_at": null,
        "last_activity_at": null,
        "observe_id": null,
        "pending_leader_transfer": null,
        "metrics": {
            "agent_count": 0,
            "active_agent_count": 0,
            "open_task_count": 0,
            "in_progress_task_count": 0,
            "blocked_task_count": 0,
            "completed_task_count": 0
        }
    }))
    .expect("migrate v5");

    assert_eq!(migrated["schema_version"], json!(CURRENT_VERSION));
    assert_eq!(migrated["title"], json!("session title"));
}

#[test]
fn merge_project_origin_preserves_existing_git_identity() {
    let merged = merge_project_origin(
        ProjectOriginRecord {
            recorded_from_dir: "/repo/.claude/worktrees/feature".to_string(),
            repository_root: None,
            checkout_root: None,
            is_worktree: false,
            worktree_name: None,
            recorded_at: "2026-04-10T10:00:00Z".to_string(),
        },
        Some(&ProjectOriginRecord {
            recorded_from_dir: "/repo/.claude/worktrees/feature".to_string(),
            repository_root: Some("/repo".to_string()),
            checkout_root: Some("/repo/.claude/worktrees/feature".to_string()),
            is_worktree: true,
            worktree_name: Some("feature".to_string()),
            recorded_at: "2026-04-10T09:00:00Z".to_string(),
        }),
    );

    assert_eq!(merged.repository_root.as_deref(), Some("/repo"));
    assert_eq!(
        merged.checkout_root.as_deref(),
        Some("/repo/.claude/worktrees/feature")
    );
    assert!(merged.is_worktree);
    assert_eq!(merged.worktree_name.as_deref(), Some("feature"));
}
