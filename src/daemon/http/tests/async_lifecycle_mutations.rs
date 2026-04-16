use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use tempfile::tempdir;

use crate::daemon::protocol::{
    AgentRemoveRequest, SessionEndRequest, SessionJoinRequest, TaskCreateRequest, TaskDropRequest,
    TaskDropTarget, TaskQueuePolicyRequest, TaskUpdateRequest,
};
use crate::session::types::{SessionRole, TaskQueuePolicy, TaskSeverity, TaskStatus};
use harness_testkit::with_isolated_harness_env;

use super::async_mutations::{
    init_git_project, start_async_http_session, test_http_state_with_empty_async_db,
};
use super::*;

async fn join_http_worker(
    state: &DaemonHttpState,
    session_id: &str,
    project_dir: &std::path::Path,
    name: &str,
) -> String {
    let response = post_session_join(
        axum::extract::Path(session_id.to_owned()),
        auth_headers(),
        State(state.clone()),
        Json(SessionJoinRequest {
            runtime: "codex".into(),
            role: SessionRole::Worker,
            fallback_role: None,
            capabilities: vec!["general".into()],
            name: Some(name.to_string()),
            project_dir: project_dir.to_string_lossy().into_owned(),
            persona: None,
        }),
    )
    .await;
    let (status, _) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);

    let async_db = state.async_db.get().expect("async db");
    let resolved = async_db
        .resolve_session(session_id)
        .await
        .expect("resolve session")
        .expect("session present");
    resolved
        .state
        .agents
        .keys()
        .find(|agent_id| agent_id.starts_with("codex-"))
        .expect("worker id")
        .to_string()
}

async fn create_http_task(
    state: &DaemonHttpState,
    session_id: &str,
    title: &str,
    severity: TaskSeverity,
) -> String {
    let response = post_task_create(
        axum::extract::Path(session_id.to_owned()),
        auth_headers(),
        State(state.clone()),
        Json(TaskCreateRequest {
            actor: "spoofed".into(),
            title: title.into(),
            context: None,
            severity,
            suggested_fix: None,
        }),
    )
    .await;
    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    body["tasks"]
        .as_array()
        .expect("tasks array")
        .iter()
        .find(|task| task["title"].as_str() == Some(title))
        .and_then(|task| task["task_id"].as_str())
        .expect("task id")
        .to_string()
}

#[test]
fn post_task_drop_queue_policy_update_and_status_use_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("http-async-lifecycle-leader")),
                ("CODEX_SESSION_ID", Some("http-async-lifecycle-worker")),
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
                        "http-async-task-lifecycle",
                    )
                    .await;
                    let worker_id = join_http_worker(
                        &state,
                        "http-async-task-lifecycle",
                        &project_dir,
                        "Async Lifecycle Worker",
                    )
                    .await;
                    let primary_task = create_http_task(
                        &state,
                        "http-async-task-lifecycle",
                        "primary task",
                        TaskSeverity::High,
                    )
                    .await;
                    let queued_task = create_http_task(
                        &state,
                        "http-async-task-lifecycle",
                        "queued task",
                        TaskSeverity::Medium,
                    )
                    .await;

                    let dropped = post_task_drop(
                        axum::extract::Path((
                            "http-async-task-lifecycle".to_owned(),
                            primary_task.clone(),
                        )),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskDropRequest {
                            actor: "spoofed".into(),
                            target: TaskDropTarget::Agent {
                                agent_id: worker_id.clone(),
                            },
                            queue_policy: TaskQueuePolicy::Locked,
                        }),
                    )
                    .await;
                    let (status, body) = response_json(dropped).await;
                    assert_eq!(status, StatusCode::OK);
                    let dropped_task = body["tasks"]
                        .as_array()
                        .expect("tasks array")
                        .iter()
                        .find(|task| task["task_id"].as_str() == Some(primary_task.as_str()))
                        .expect("primary task");
                    assert_eq!(
                        dropped_task["assigned_to"].as_str(),
                        Some(worker_id.as_str())
                    );
                    assert_eq!(body["signals"].as_array().map(Vec::len), Some(1));

                    let queued = post_task_drop(
                        axum::extract::Path((
                            "http-async-task-lifecycle".to_owned(),
                            queued_task.clone(),
                        )),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskDropRequest {
                            actor: "spoofed".into(),
                            target: TaskDropTarget::Agent {
                                agent_id: worker_id.clone(),
                            },
                            queue_policy: TaskQueuePolicy::Locked,
                        }),
                    )
                    .await;
                    let (status, body) = response_json(queued).await;
                    assert_eq!(status, StatusCode::OK);
                    let queued_task_body = body["tasks"]
                        .as_array()
                        .expect("tasks array")
                        .iter()
                        .find(|task| task["task_id"].as_str() == Some(queued_task.as_str()))
                        .expect("queued task");
                    assert!(queued_task_body["queue_policy"].is_null());

                    let updated_policy = post_task_queue_policy(
                        axum::extract::Path((
                            "http-async-task-lifecycle".to_owned(),
                            queued_task.clone(),
                        )),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskQueuePolicyRequest {
                            actor: "spoofed".into(),
                            queue_policy: TaskQueuePolicy::ReassignWhenFree,
                        }),
                    )
                    .await;
                    let (status, body) = response_json(updated_policy).await;
                    assert_eq!(status, StatusCode::OK);
                    let queued_task_body = body["tasks"]
                        .as_array()
                        .expect("tasks array")
                        .iter()
                        .find(|task| task["task_id"].as_str() == Some(queued_task.as_str()))
                        .expect("queued task");
                    assert_eq!(
                        queued_task_body["queue_policy"].as_str(),
                        Some("reassign_when_free")
                    );

                    let completed = post_task_update(
                        axum::extract::Path((
                            "http-async-task-lifecycle".to_owned(),
                            primary_task.clone(),
                        )),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskUpdateRequest {
                            actor: "spoofed".into(),
                            status: TaskStatus::Done,
                            note: Some("completed".into()),
                        }),
                    )
                    .await;
                    let (status, body) = response_json(completed).await;
                    assert_eq!(status, StatusCode::OK);
                    let primary_task_body = body["tasks"]
                        .as_array()
                        .expect("tasks array")
                        .iter()
                        .find(|task| task["task_id"].as_str() == Some(primary_task.as_str()))
                        .expect("primary task");
                    let queued_task_body = body["tasks"]
                        .as_array()
                        .expect("tasks array")
                        .iter()
                        .find(|task| task["task_id"].as_str() == Some(queued_task.as_str()))
                        .expect("queued task");
                    assert_eq!(primary_task_body["status"].as_str(), Some("done"));
                    assert_eq!(queued_task_body["status"].as_str(), Some("open"));
                });
            },
        );
    });
}

#[test]
fn post_remove_agent_and_end_session_use_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("http-async-end-leader")),
                ("CODEX_SESSION_ID", Some("http-async-end-worker")),
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
                        "http-async-session-lifecycle",
                    )
                    .await;
                    let worker_id = join_http_worker(
                        &state,
                        "http-async-session-lifecycle",
                        &project_dir,
                        "Async Session Worker",
                    )
                    .await;

                    let removed = post_remove_agent(
                        axum::extract::Path((
                            "http-async-session-lifecycle".to_owned(),
                            worker_id.clone(),
                        )),
                        auth_headers(),
                        State(state.clone()),
                        Json(AgentRemoveRequest {
                            actor: "spoofed".into(),
                        }),
                    )
                    .await;
                    let (status, body) = response_json(removed).await;
                    assert_eq!(status, StatusCode::OK);
                    assert!(
                        body["agents"]
                            .as_array()
                            .expect("agents array")
                            .iter()
                            .all(|agent| agent["agent_id"].as_str() != Some(worker_id.as_str()))
                    );
                    assert_eq!(body["signals"].as_array().map(Vec::len), Some(1));

                    let ended = post_end_session(
                        axum::extract::Path("http-async-session-lifecycle".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SessionEndRequest {
                            actor: "spoofed".into(),
                        }),
                    )
                    .await;
                    let (status, body) = response_json(ended).await;
                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(body["session"]["status"].as_str(), Some("ended"));
                    assert!(body["session"]["leader_id"].is_null());
                });
            },
        );
    });
}
