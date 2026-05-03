use fs_err as fs;
use serde_json::{Value, json, to_value};

use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::session::types::{AgentStatus, CURRENT_VERSION};
use crate::workspace::layout::SessionLayout;

use super::state_store::{create_state, load_state};
use super::test_support::sample_state;

fn test_layout(tmp: &std::path::Path, session_id: &str) -> SessionLayout {
    SessionLayout {
        sessions_root: tmp.join("sessions"),
        project_name: "demo".into(),
        session_id: session_id.to_string(),
    }
}

fn legacy_state_value(session_id: &str, schema_version: u64) -> Value {
    let mut value = to_value(sample_state(session_id)).expect("serialize legacy state");
    value
        .as_object_mut()
        .expect("state object")
        .insert("schema_version".into(), json!(schema_version));
    value
}

#[test]
fn state_file_uses_new_layout() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let layout = test_layout(tmp.path(), "abc12345");
    fs::create_dir_all(layout.session_root()).expect("create session dir");

    let state = sample_state("abc12345");
    assert!(create_state(&layout, &state).expect("create"));

    assert!(
        layout.state_file().exists(),
        "state.json must be in session_root"
    );
}

#[test]
fn state_round_trip_via_repository() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let layout = test_layout(tmp.path(), "sess-1");
    fs::create_dir_all(layout.session_root()).expect("create session dir");

    let state = sample_state("sess-1");
    assert!(create_state(&layout, &state).expect("create"));
    let loaded = load_state(&layout).expect("load").expect("state");
    assert_eq!(loaded.session_id, "sess-1");
    assert_eq!(loaded.observe_id.as_deref(), Some("observe-sess-1"));
}

#[test]
fn load_state_migrates_v3_state_and_persists_current_schema() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let session_id = "sess-legacy";
    let layout = test_layout(tmp.path(), session_id);
    fs::create_dir_all(layout.session_root()).expect("create session dir");

    let state_file = layout.state_file();
    write_json_pretty(
        &state_file,
        &json!({
            "schema_version": 3,
            "state_version": 7,
            "session_id": session_id,
            "context": "legacy context",
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
        }),
    )
    .expect("write legacy state");

    let loaded = load_state(&layout)
        .expect("load state")
        .expect("state present");
    assert_eq!(loaded.schema_version, CURRENT_VERSION);
    assert_eq!(loaded.title, "legacy context");
    assert!(loaded.policy.leader_join.require_explicit_fallback_role);
    assert_eq!(
        loaded.policy.degraded_recovery.preset_id.as_deref(),
        Some("swarm-default")
    );

    let persisted: Value = read_json_typed(&state_file).expect("read migrated state");
    assert_eq!(persisted["schema_version"], json!(CURRENT_VERSION));
    assert_eq!(persisted["title"], json!("legacy context"));
    assert_eq!(
        persisted["policy"]["degraded_recovery"]["preset_id"],
        json!("swarm-default")
    );
}

#[test]
fn state_defaults_external_origin_none() {
    let state = sample_state("abc12345");
    assert_eq!(state.schema_version, CURRENT_VERSION);
    assert!(state.external_origin.is_none());
    assert!(state.adopted_at.is_none());
}

#[test]
fn load_state_migrates_v8_state_to_v9_passthrough() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let layout = test_layout(tmp.path(), "sess-v8");
    fs::create_dir_all(layout.session_root()).expect("create session dir");
    write_json_pretty(
        &layout.state_file(),
        &json!({
            "schema_version": 8,
            "state_version": 0,
            "session_id": "sess-v8",
            "project_name": "demo",
            "worktree_path": "",
            "shared_path": "",
            "origin_path": "",
            "branch_ref": "",
            "title": "t",
            "context": "c",
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
        }),
    )
    .expect("write v8 state");

    let loaded = load_state(&layout).expect("load").expect("state");
    assert_eq!(loaded.schema_version, CURRENT_VERSION);
    assert!(loaded.external_origin.is_none());
    assert!(loaded.adopted_at.is_none());

    let persisted: Value = read_json_typed(&layout.state_file()).expect("read migrated");
    assert_eq!(persisted["schema_version"], json!(CURRENT_VERSION));
    // Fields with Option::is_none skipped during serialize
    assert!(
        persisted
            .get("external_origin")
            .is_none_or(serde_json::Value::is_null)
    );
}

#[test]
fn create_state_rejects_unsafe_session_id() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let escape_dir = tmp.path().join("escape");
    let unsafe_id = escape_dir.to_string_lossy().into_owned();

    let layout = SessionLayout {
        sessions_root: tmp.path().join("sessions"),
        project_name: "demo".into(),
        session_id: unsafe_id.clone(),
    };
    let state = sample_state(&unsafe_id);

    let error = create_state(&layout, &state).expect_err("unsafe id");
    assert_eq!(error.code(), "KSRCLI059");
    assert!(!escape_dir.join("state.json").exists());
}

#[test]
fn load_state_migrates_v10_unknown_runtime_without_bricking() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let session_id = "sess-v10-runtime";
    let layout = test_layout(tmp.path(), session_id);
    fs::create_dir_all(layout.session_root()).expect("create session dir");

    let mut state = legacy_state_value(session_id, 10);
    let agent = state["agents"]["claude-leader"]
        .as_object_mut()
        .expect("agent object");
    agent.insert("runtime".into(), json!("future-acp-runtime"));
    agent.insert("status".into(), json!("disconnected"));
    write_json_pretty(&layout.state_file(), &state).expect("write v10 state");

    let loaded = load_state(&layout).expect("load").expect("state");
    let agent = loaded.agents.get("claude-leader").expect("agent");
    assert_eq!(loaded.schema_version, CURRENT_VERSION);
    assert_eq!(agent.runtime.runtime_name(), "future-acp-runtime");
    assert!(agent.managed_agent.is_none());
    assert!(matches!(
        agent.status,
        AgentStatus::Disconnected {
            reason: _,
            stderr_tail: _
        }
    ));

    let persisted: Value = read_json_typed(&layout.state_file()).expect("read migrated");
    assert_eq!(persisted["schema_version"], json!(CURRENT_VERSION));
    assert_eq!(
        persisted["agents"]["claude-leader"]["runtime"],
        json!({ "kind": "acp", "id": "future-acp-runtime" })
    );
    assert_eq!(
        persisted["agents"]["claude-leader"]["status"]["state"],
        json!("disconnected")
    );
}

#[test]
fn load_state_migrates_v11_blank_tui_marker_by_quarantining_row() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let session_id = "sess-v11-blank";
    let layout = test_layout(tmp.path(), session_id);
    fs::create_dir_all(layout.session_root()).expect("create session dir");

    let mut state = legacy_state_value(session_id, 11);
    let agent = state["agents"]["claude-leader"]
        .as_object_mut()
        .expect("agent object");
    agent.insert("capabilities".into(), json!(["review", "agent-tui:   "]));
    write_json_pretty(&layout.state_file(), &state).expect("write v11 state");

    let loaded = load_state(&layout).expect("load").expect("state");
    let agent = loaded.agents.get("claude-leader").expect("agent");
    assert_eq!(loaded.schema_version, CURRENT_VERSION);
    assert_eq!(agent.capabilities, vec!["review"]);
    assert!(agent.managed_agent.is_none());

    let persisted: Value = read_json_typed(&layout.state_file()).expect("read migrated");
    assert_eq!(persisted["schema_version"], json!(CURRENT_VERSION));
    assert_eq!(
        persisted["agents"]["claude-leader"]["capabilities"],
        json!(["review"])
    );
    assert!(
        persisted["agents"]["claude-leader"]
            .get("managed_agent")
            .is_none_or(serde_json::Value::is_null)
    );
}

#[test]
fn load_state_migrates_v11_conflicting_tui_markers_without_bricking_good_rows() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let session_id = "sess-v11-conflict";
    let layout = test_layout(tmp.path(), session_id);
    fs::create_dir_all(layout.session_root()).expect("create session dir");

    let mut state = legacy_state_value(session_id, 11);
    let agents = state["agents"].as_object_mut().expect("agents object");
    let mut good_agent = agents
        .get("claude-leader")
        .cloned()
        .expect("template agent");
    let good_object = good_agent.as_object_mut().expect("good agent object");
    good_object.insert("agent_id".into(), json!("codex-reviewer"));
    good_object.insert("name".into(), json!("codex reviewer"));
    good_object.insert("runtime".into(), json!("codex"));
    good_object.insert("role".into(), json!("worker"));
    good_object.insert("capabilities".into(), json!(["review", "agent-tui:tty-good"]));
    agents.insert("codex-reviewer".into(), good_agent);

    let bad_agent = agents
        .get_mut("claude-leader")
        .and_then(Value::as_object_mut)
        .expect("bad agent object");
    bad_agent.insert(
        "capabilities".into(),
        json!(["review", "agent-tui:tty-one", "agent-tui:tty-two"]),
    );
    write_json_pretty(&layout.state_file(), &state).expect("write v11 state");

    let loaded = load_state(&layout).expect("load").expect("state");
    assert_eq!(loaded.schema_version, CURRENT_VERSION);
    assert!(loaded.agents["claude-leader"].managed_agent.is_none());
    assert_eq!(loaded.agents["claude-leader"].capabilities, vec!["review"]);
    assert_eq!(
        loaded.agents["codex-reviewer"]
            .managed_agent
            .as_ref()
            .map(|managed| managed.id.as_str()),
        Some("tty-good")
    );

    let persisted: Value = read_json_typed(&layout.state_file()).expect("read migrated");
    assert_eq!(
        persisted["agents"]["claude-leader"]["capabilities"],
        json!(["review"])
    );
    assert_eq!(
        persisted["agents"]["codex-reviewer"]["managed_agent"],
        json!({ "kind": "tui", "id": "tty-good" })
    );
}
