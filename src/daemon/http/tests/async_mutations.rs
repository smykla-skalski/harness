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
use crate::daemon::protocol::{TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest};
use crate::daemon::state::DaemonManifest;
use crate::session::types::SessionRole;
use harness_testkit::with_isolated_harness_env;

use super::*;

pub(super) async fn test_http_state_with_empty_async_db(
    db_path: &std::path::Path,
) -> DaemonHttpState {
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
        async_db: super::super::AsyncDaemonDbSlot::from_inner(async_db_slot.clone()),
        db_path: Some(db_path.to_path_buf()),
        codex_controller: CodexControllerHandle::new_with_async_db(
            sender.clone(),
            db_slot.clone(),
            async_db_slot.clone(),
            false,
        ),
        agent_tui_manager: AgentTuiManagerHandle::new_with_async_db(
            sender,
            db_slot,
            async_db_slot,
            false,
        ),
    }
}

pub(super) fn init_git_project(project_dir: &std::path::Path) {
    fs::create_dir_all(project_dir).expect("create project dir");
    let status = Command::new("git")
        .arg("init")
        .arg("-q")
        .arg(project_dir)
        .status()
        .expect("git init");
    assert!(status.success(), "git init should succeed");
}

pub(super) async fn start_async_http_session(
    state: DaemonHttpState,
    project_dir: &std::path::Path,
    session_id: &str,
) -> serde_json::Value {
    let response = post_session_start(
        auth_headers(),
        State(state),
        Json(SessionStartRequest {
            title: format!("{session_id} title"),
            context: format!("{session_id} context"),
            runtime: "claude".into(),
            session_id: Some(session_id.to_string()),
            project_dir: project_dir.to_string_lossy().into_owned(),
            policy_preset: None,
        }),
    )
    .await;
    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    body
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

                let body =
                    start_async_http_session(state.clone(), &project_dir, "http-async-start").await;
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
                assert_eq!(resolved.state.title, "http-async-start title");
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

                    let _ =
                        start_async_http_session(state.clone(), &project_dir, "http-async-join")
                            .await;

                    let response = post_session_join(
                        axum::extract::Path("http-async-join".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            fallback_role: None,
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

#[test]
fn post_task_create_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var("CLAUDE_SESSION_ID", Some("http-async-task-create"), || {
            let project_dir = sandbox.path().join("project");
            init_git_project(&project_dir);

            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = sandbox.path().join("daemon.sqlite");
                let state = test_http_state_with_empty_async_db(&db_path).await;
                let _ =
                    start_async_http_session(state.clone(), &project_dir, "http-async-task").await;

                let response = post_task_create(
                    axum::extract::Path("http-async-task".to_owned()),
                    auth_headers(),
                    State(state.clone()),
                    Json(TaskCreateRequest {
                        actor: "spoofed".into(),
                        title: "async http task".into(),
                        context: Some("create via async route".into()),
                        severity: crate::session::types::TaskSeverity::High,
                        suggested_fix: Some("prefer sqlx pool".into()),
                    }),
                )
                .await;

                let (status, body) = response_json(response).await;
                assert_eq!(status, StatusCode::OK);
                assert_eq!(body["tasks"][0]["title"].as_str(), Some("async http task"));
            });
        });
    });
}

#[test]
fn post_task_assign_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("http-async-task-assign-leader")),
                ("CODEX_SESSION_ID", Some("http-async-task-assign-worker")),
            ],
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let _ = start_async_http_session(
                        state.clone(),
                        &project_dir,
                        "http-async-task-assign",
                    )
                    .await;
                    let _ = post_session_join(
                        axum::extract::Path("http-async-task-assign".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            fallback_role: None,
                            capabilities: vec!["general".into()],
                            name: Some("Async Task Worker".into()),
                            project_dir: project_dir.to_string_lossy().into_owned(),
                            persona: None,
                        }),
                    )
                    .await;
                    let created = post_task_create(
                        axum::extract::Path("http-async-task-assign".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskCreateRequest {
                            actor: "spoofed".into(),
                            title: "assign me".into(),
                            context: None,
                            severity: crate::session::types::TaskSeverity::Medium,
                            suggested_fix: None,
                        }),
                    )
                    .await;
                    let (_, created_body) = response_json(created).await;
                    let task_id = created_body["tasks"][0]["task_id"]
                        .as_str()
                        .expect("task id")
                        .to_string();

                    let async_db = state.async_db.get().expect("async db");
                    let resolved = async_db
                        .resolve_session("http-async-task-assign")
                        .await
                        .expect("resolve session")
                        .expect("session present");
                    let worker_id = resolved
                        .state
                        .agents
                        .keys()
                        .find(|agent_id| agent_id.starts_with("codex-"))
                        .expect("worker id")
                        .to_string();

                    let response = post_task_assign(
                        axum::extract::Path(("http-async-task-assign".to_owned(), task_id)),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskAssignRequest {
                            actor: "spoofed".into(),
                            agent_id: worker_id.clone(),
                        }),
                    )
                    .await;

                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(
                        body["tasks"][0]["assigned_to"].as_str(),
                        Some(worker_id.as_str())
                    );
                });
            },
        );
    });
}

#[test]
fn post_task_checkpoint_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("http-async-task-checkpoint"),
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let _ = start_async_http_session(
                        state.clone(),
                        &project_dir,
                        "http-async-task-checkpoint",
                    )
                    .await;
                    let created = post_task_create(
                        axum::extract::Path("http-async-task-checkpoint".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskCreateRequest {
                            actor: "spoofed".into(),
                            title: "checkpoint me".into(),
                            context: None,
                            severity: crate::session::types::TaskSeverity::Low,
                            suggested_fix: None,
                        }),
                    )
                    .await;
                    let (_, created_body) = response_json(created).await;
                    let task_id = created_body["tasks"][0]["task_id"]
                        .as_str()
                        .expect("task id")
                        .to_string();

                    let response = post_task_checkpoint(
                        axum::extract::Path((
                            "http-async-task-checkpoint".to_owned(),
                            task_id.clone(),
                        )),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskCheckpointRequest {
                            actor: "spoofed".into(),
                            summary: "Halfway there".into(),
                            progress: 50,
                        }),
                    )
                    .await;

                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(
                        body["tasks"][0]["checkpoint_summary"]["summary"].as_str(),
                        Some("Halfway there")
                    );
                });
            },
        );
    });
}
