use std::process::Command;
use std::sync::{Arc, Mutex, OnceLock};

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use fs_err as fs;
use tempfile::tempdir;
use tokio::sync::broadcast;

use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{SessionJoinRequest, SessionStartRequest};
use crate::daemon::state::DaemonManifest;
use harness_testkit::with_isolated_harness_env;

use super::*;

async fn test_http_state_with_empty_async_db(db_path: &std::path::Path) -> DaemonHttpState {
    let (sender, _) = broadcast::channel(8);
    let db_slot = Arc::new(OnceLock::new());
    let async_db_slot = Arc::new(OnceLock::new());

    assert!(
        async_db_slot
            .set(Arc::new(
                AsyncDaemonDb::connect(db_path)
                    .await
                    .expect("open async daemon db"),
            ))
            .is_ok(),
        "install async db"
    );

    let manifest: DaemonManifest = serde_json::from_value(serde_json::json!({
        "version": "20.6.0",
        "pid": 1,
        "endpoint": "http://127.0.0.1:0",
        "started_at": "2026-04-13T00:00:00Z",
        "token_path": "/tmp/token",
        "sandboxed": false,
        "host_bridge": {},
        "revision": 0,
        "updated_at": "",
        "binary_stamp": null,
    }))
    .expect("deserialize daemon manifest");

    DaemonHttpState {
        token: "token".into(),
        sender: sender.clone(),
        manifest,
        daemon_epoch: "epoch".into(),
        replay_buffer: Arc::new(Mutex::new(crate::daemon::websocket::ReplayBuffer::new(8))),
        db: db_slot.clone(),
        async_db: super::super::AsyncDaemonDbSlot::from_inner(async_db_slot),
        db_path: Some(db_path.to_path_buf()),
        codex_controller: CodexControllerHandle::new(sender.clone(), db_slot.clone(), false),
        agent_tui_manager: AgentTuiManagerHandle::new(sender, db_slot, false),
    }
}

fn init_git_project(project_dir: &std::path::Path) {
    fs::create_dir_all(project_dir).expect("create project dir");
    let status = Command::new("git")
        .arg("init")
        .arg("-q")
        .arg(project_dir)
        .status()
        .expect("git init");
    assert!(status.success(), "git init should succeed");
}

#[test]
fn post_session_start_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var("CLAUDE_SESSION_ID", Some("http-async-start-leader"), || {
            let project_dir = sandbox.path().join("project");
            init_git_project(&project_dir);

            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = sandbox.path().join("daemon.sqlite");
                let state = test_http_state_with_empty_async_db(&db_path).await;

                let response = post_session_start(
                    auth_headers(),
                    State(state.clone()),
                    Json(SessionStartRequest {
                        title: "async http start".into(),
                        context: "async-only session creation".into(),
                        runtime: "claude".into(),
                        session_id: Some("http-async-start".into()),
                        project_dir: project_dir.to_string_lossy().into_owned(),
                    }),
                )
                .await;

                let (status, body) = response_json(response).await;
                assert_eq!(status, StatusCode::OK);
                assert_eq!(
                    body["state"]["session_id"].as_str(),
                    Some("http-async-start")
                );

                let async_db = state.async_db.get().expect("async db");
                let resolved = async_db
                    .resolve_session("http-async-start")
                    .await
                    .expect("resolve session")
                    .expect("session present");
                assert_eq!(resolved.state.title, "async http start");
                assert_eq!(
                    resolved.project.project_dir.as_deref(),
                    Some(
                        project_dir
                            .canonicalize()
                            .expect("canonical project")
                            .as_path()
                    )
                );
            });
        });
    });
}

#[test]
fn post_session_join_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("http-async-join-leader")),
                ("CODEX_SESSION_ID", Some("http-async-join-worker")),
            ],
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;

                    let start_response = post_session_start(
                        auth_headers(),
                        State(state.clone()),
                        Json(SessionStartRequest {
                            title: "async http join".into(),
                            context: "seed session".into(),
                            runtime: "claude".into(),
                            session_id: Some("http-async-join".into()),
                            project_dir: project_dir.to_string_lossy().into_owned(),
                        }),
                    )
                    .await;
                    assert_eq!(start_response.status(), StatusCode::OK);

                    let response = post_session_join(
                        axum::extract::Path("http-async-join".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            capabilities: vec!["general".into()],
                            name: Some("Async HTTP Worker".into()),
                            project_dir: project_dir.to_string_lossy().into_owned(),
                            persona: None,
                        }),
                    )
                    .await;

                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(
                        body["state"]["session_id"].as_str(),
                        Some("http-async-join")
                    );
                    assert_eq!(
                        body["state"]["agents"]
                            .as_object()
                            .map(|agents| agents.len()),
                        Some(2)
                    );

                    let async_db = state.async_db.get().expect("async db");
                    let resolved = async_db
                        .resolve_session("http-async-join")
                        .await
                        .expect("resolve session")
                        .expect("session present");
                    assert_eq!(resolved.state.agents.len(), 2);
                });
            },
        );
    });
}
