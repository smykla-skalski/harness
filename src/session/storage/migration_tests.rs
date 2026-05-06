use serde_json::json;

use super::migrations::{
    migrate_v1_to_v2, migrate_v2_to_v3, migrate_v3_to_v4, migrate_v4_to_v5, migrate_v5_to_v6,
    migrate_v6_to_v7, migrate_v7_to_v8, migrate_v10_to_v11, migrate_v11_to_v12, migrate_v12_to_v13,
    migrate_v13_to_v14,
};
#[test]
fn migrate_v1_and_v2_stamp_expected_schema_versions() {
    let v1 = json!({
        "schema_version": 1,
        "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
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
        "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
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
        "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
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
        "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
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
        "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
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

    assert_eq!(migrated["schema_version"], json!(6));
    assert_eq!(migrated["title"], json!("session title"));
}

#[test]
fn migrate_v6_to_v7_backfills_swarm_policy() {
    let migrated = migrate_v6_to_v7(json!({
        "schema_version": 6,
        "state_version": 3,
        "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
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
            "idle_agent_count": 0,
            "open_task_count": 0,
            "in_progress_task_count": 0,
            "blocked_task_count": 0,
            "completed_task_count": 0
        }
    }))
    .expect("migrate v6");

    assert_eq!(migrated["schema_version"], json!(7));
    assert_eq!(
        migrated["policy"],
        json!({
            "leader_join": {
                "require_explicit_fallback_role": true
            },
            "auto_promotion": {
                "role_order": ["improver", "reviewer", "observer", "worker"],
                "priority_preset_id": "swarm-default"
            },
            "degraded_recovery": {
                "preset_id": "swarm-default",
                "manual_recovery_allowed": true
            }
        })
    );
}

#[test]
fn migrate_v7_to_v8_adds_layout_fields() {
    let migrated = migrate_v7_to_v8(json!({
        "schema_version": 7,
        "state_version": 3,
        "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
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
        "metrics": {}
    }))
    .expect("migrate v7");

    assert_eq!(migrated["schema_version"], json!(8));
    assert_eq!(migrated["project_name"], json!(""));
    assert_eq!(migrated["worktree_path"], json!(""));
    assert_eq!(migrated["shared_path"], json!(""));
    assert_eq!(migrated["origin_path"], json!(""));
    assert_eq!(migrated["branch_ref"], json!(""));
}

#[test]
fn migrate_v10_to_v11_tags_runtime_and_disconnect_status() {
    let migrated = migrate_v10_to_v11(json!({
        "schema_version": 10,
        "state_version": 3,
        "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
        "title": "x",
        "context": "y",
        "status": "active",
        "created_at": "t",
        "updated_at": "t",
        "agents": {
            "a-claude": {
                "agent_id": "a-claude",
                "name": "Claude",
                "runtime": "claude",
                "role": "leader",
                "joined_at": "t",
                "updated_at": "t",
                "status": "active"
            },
            "a-gone": {
                "agent_id": "a-gone",
                "name": "Worker",
                "runtime": "codex",
                "role": "worker",
                "joined_at": "t",
                "updated_at": "t",
                "status": "disconnected"
            },
            "a-future": {
                "agent_id": "a-future",
                "name": "Future",
                "runtime": "mystery-agent",
                "role": "worker",
                "joined_at": "t",
                "updated_at": "t",
                "status": "idle"
            }
        },
        "tasks": {}
    }))
    .expect("migrate v10");

    assert_eq!(migrated["schema_version"], json!(11));
    assert_eq!(
        migrated["agents"]["a-claude"]["runtime"],
        json!({ "kind": "tui", "id": "claude" })
    );
    assert_eq!(migrated["agents"]["a-claude"]["status"], json!("active"));
    assert_eq!(
        migrated["agents"]["a-gone"]["status"],
        json!({ "state": "disconnected", "reason": { "kind": "unknown" } })
    );
    assert_eq!(
        migrated["agents"]["a-future"]["runtime"],
        json!({ "kind": "acp", "id": "mystery-agent" })
    );
    assert_eq!(migrated["agents"]["a-future"]["status"], json!("idle"));
}

#[test]
fn migrate_v10_to_v11_is_idempotent_on_already_tagged_state() {
    let migrated = migrate_v10_to_v11(json!({
        "schema_version": 10,
        "agents": {
            "a-already-tagged": {
                "agent_id": "a-already-tagged",
                "runtime": { "kind": "acp", "id": "copilot" },
                "status": "active"
            }
        },
        "tasks": {}
    }))
    .expect("migrate v10");

    assert_eq!(
        migrated["agents"]["a-already-tagged"]["runtime"],
        json!({ "kind": "acp", "id": "copilot" })
    );
    assert_eq!(
        migrated["agents"]["a-already-tagged"]["status"],
        json!("active")
    );
}

#[test]
fn migrate_v11_to_v12_backfills_tui_managed_agent_from_legacy_capability() {
    let migrated = migrate_v11_to_v12(json!({
        "schema_version": 11,
        "agents": {
            "agent-1": {
                "agent_id": "agent-1",
                "capabilities": ["review", "agent-tui: agent-tui-1 "]
            }
        },
        "tasks": {}
    }))
    .expect("migrate v11");

    assert_eq!(migrated["schema_version"], json!(12));
    assert_eq!(
        migrated["agents"]["agent-1"]["managed_agent"],
        json!({ "kind": "tui", "id": "agent-tui-1" })
    );
}

#[test]
fn migrate_v13_to_v14_renames_legacy_session_fields_and_flattens_managed_agent_identity() {
    let migrated = migrate_v13_to_v14(json!({
        "schema_version": 13,
        "agents": {
            "agent-1": {
                "agent_id": "agent-1",
                "agent_session_id": "runtime-1",
                "managed_agent": {
                    "kind": "acp",
                    "id": "acp-1"
                }
            }
        },
        "tasks": {}
    }))
    .expect("migrate v13");

    assert_eq!(migrated["schema_version"], json!(14));
    assert!(
        migrated["agents"]["agent-1"]
            .get("managed_agent")
            .is_none_or(serde_json::Value::is_null)
    );
    assert_eq!(
        migrated["agents"]["agent-1"]["managed_agent_family"],
        json!("acp")
    );
    assert_eq!(
        migrated["agents"]["agent-1"]["managed_agent_id"],
        json!("acp-1")
    );
    assert_eq!(
        migrated["agents"]["agent-1"]["session_agent_id"],
        json!("agent-1")
    );
    assert_eq!(
        migrated["agents"]["agent-1"]["runtime_session_id"],
        json!("runtime-1")
    );
    assert!(
        migrated["agents"]["agent-1"]
            .get("agent_id")
            .is_none_or(serde_json::Value::is_null)
    );
    assert!(
        migrated["agents"]["agent-1"]
            .get("agent_session_id")
            .is_none_or(serde_json::Value::is_null)
    );
}

#[test]
fn migrate_v13_to_v14_rejects_malformed_legacy_managed_agent() {
    let error = migrate_v13_to_v14(json!({
        "schema_version": 13,
        "agents": {
            "agent-1": {
                "agent_id": "agent-1",
                "managed_agent": "acp-1"
            }
        },
        "tasks": {}
    }))
    .expect_err("invalid managed_agent should fail");

    assert!(
        error.to_string().contains("invalid managed_agent object"),
        "expected managed_agent object error, got {error}"
    );
}

#[test]
fn migrate_v13_to_v14_rejects_partial_flattened_managed_agent_with_legacy_shape() {
    let error = migrate_v13_to_v14(json!({
        "schema_version": 13,
        "agents": {
            "agent-1": {
                "agent_id": "agent-1",
                "managed_agent": {
                    "kind": "acp",
                    "id": "acp-1"
                },
                "managed_agent_id": "acp-1"
            }
        },
        "tasks": {}
    }))
    .expect_err("mixed partial managed-agent identity should fail");

    assert!(
        error
            .to_string()
            .contains("must not mix legacy managed_agent with partial flattened fields"),
        "expected partial managed-agent error, got {error}"
    );
}

#[test]
fn migrate_v11_to_v12_quarantines_blank_tui_marker_ids() {
    let migrated = migrate_v11_to_v12(json!({
        "schema_version": 11,
        "agents": {
            "agent-1": {
                "agent_id": "agent-1",
                "capabilities": ["review", "agent-tui:   "]
            }
        },
        "tasks": {}
    }))
    .expect("blank marker should be quarantined");

    assert_eq!(migrated["schema_version"], json!(12));
    assert_eq!(
        migrated["agents"]["agent-1"]["capabilities"],
        json!(["review"])
    );
    assert!(
        migrated["agents"]["agent-1"]
            .get("managed_agent")
            .is_none_or(serde_json::Value::is_null)
    );
}

#[test]
fn migrate_v11_to_v12_quarantines_conflicting_tui_marker_ids() {
    let migrated = migrate_v11_to_v12(json!({
        "schema_version": 11,
        "agents": {
            "agent-1": {
                "agent_id": "agent-1",
                "capabilities": ["review", "agent-tui:one", "agent-tui:two"]
            }
        },
        "tasks": {}
    }))
    .expect("conflicting markers should be quarantined");

    assert_eq!(migrated["schema_version"], json!(12));
    assert_eq!(
        migrated["agents"]["agent-1"]["capabilities"],
        json!(["review"])
    );
    assert!(
        migrated["agents"]["agent-1"]
            .get("managed_agent")
            .is_none_or(serde_json::Value::is_null)
    );
}

#[test]
fn migrate_v12_to_v13_clears_legacy_end_session_archive_timestamp() {
    let migrated = migrate_v12_to_v13(json!({
        "schema_version": 12,
        "state_version": 3,
        "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
        "title": "session title",
        "context": "session goal",
        "status": "ended",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "agents": {},
        "tasks": {},
        "leader_id": null,
        "archived_at": "2026-01-01T00:10:00Z",
        "last_activity_at": null,
        "observe_id": null,
        "pending_leader_transfer": null,
        "metrics": {}
    }))
    .expect("migrate v12");

    assert_eq!(migrated["schema_version"], json!(13));
    assert!(migrated["archived_at"].is_null());
}
