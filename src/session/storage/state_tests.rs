use fs_err as fs;
use serde_json::{json, Value};

use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::session::types::CURRENT_VERSION;

use super::files::state_path;
use super::state_store::{create_state, load_state};
use super::test_support::sample_state;

#[test]
fn state_round_trip_via_repository() {
    let tmp = tempfile::tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("CLAUDE_SESSION_ID", Some("test-storage")),
        ],
        || {
            let project = tmp.path().join("project");
            let state = sample_state("sess-1");
            assert!(create_state(&project, "sess-1", &state).expect("create"));
            let loaded = load_state(&project, "sess-1")
                .expect("load")
                .expect("state");
            assert_eq!(loaded.session_id, "sess-1");
            assert_eq!(loaded.observe_id.as_deref(), Some("observe-sess-1"));
        },
    );
}

#[test]
fn load_state_migrates_v3_state_and_persists_current_schema() {
    let tmp = tempfile::tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("CLAUDE_SESSION_ID", Some("test-session-migration")),
        ],
        || {
            let project = tmp.path().join("project");
            let session_id = "sess-legacy";
            let state_file = state_path(&project, session_id).expect("state path");
            if let Some(parent) = state_file.parent() {
                fs::create_dir_all(parent).expect("create session dir");
            }
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

            let loaded = load_state(&project, session_id)
                .expect("load state")
                .expect("state present");
            assert_eq!(loaded.schema_version, CURRENT_VERSION);
            assert_eq!(loaded.title, "legacy context");

            let persisted: Value = read_json_typed(&state_file).expect("read migrated state");
            assert_eq!(persisted["schema_version"], json!(CURRENT_VERSION));
            assert_eq!(persisted["title"], json!("legacy context"));
        },
    );
}

#[test]
fn create_state_rejects_unsafe_session_id() {
    let tmp = tempfile::tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("CLAUDE_SESSION_ID", Some("test-unsafe-session-id")),
        ],
        || {
            let project = tmp.path().join("project");
            let escape_dir = tmp.path().join("escape");
            let unsafe_id = escape_dir.to_string_lossy().into_owned();
            let state = sample_state(&unsafe_id);

            let error = create_state(&project, &unsafe_id, &state).expect_err("unsafe id");
            assert_eq!(error.code(), "KSRCLI059");
            assert!(!escape_dir.join("state.json").exists());
        },
    );
}
