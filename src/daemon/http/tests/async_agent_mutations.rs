use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use tempfile::tempdir;

use crate::daemon::protocol::{LeaderTransferRequest, RoleChangeRequest, SessionJoinRequest};
use crate::session::types::SessionRole;
use harness_testkit::with_isolated_harness_env;

use super::async_mutations::{
    init_git_project, start_async_http_session, test_http_state_with_empty_async_db,
};
use super::*;

#[test]
fn post_role_change_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("http-async-role-leader")),
                ("CODEX_SESSION_ID", Some("http-async-role-worker")),
            ],
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let _ =
                        start_async_http_session(state.clone(), &project_dir, "http-async-role")
                            .await;
                    let _ = post_session_join(
                        axum::extract::Path("http-async-role".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            capabilities: vec!["general".into()],
                            name: Some("Async Role Worker".into()),
                            project_dir: project_dir.to_string_lossy().into_owned(),
                            persona: None,
                        }),
                    )
                    .await;
                    let async_db = state.async_db.get().expect("async db");
                    let resolved = async_db
                        .resolve_session("http-async-role")
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

                    let response = post_role_change(
                        axum::extract::Path(("http-async-role".to_owned(), worker_id.clone())),
                        auth_headers(),
                        State(state.clone()),
                        Json(RoleChangeRequest {
                            actor: "spoofed".into(),
                            role: SessionRole::Reviewer,
                            reason: Some("route review".into()),
                        }),
                    )
                    .await;

                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);
                    let role = body["agents"]
                        .as_array()
                        .expect("agents array")
                        .iter()
                        .find(|agent| agent["agent_id"].as_str() == Some(worker_id.as_str()))
                        .and_then(|agent| agent["role"].as_str());
                    assert_eq!(role, Some("reviewer"));
                });
            },
        );
    });
}

#[test]
fn post_transfer_leader_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("http-async-transfer-leader")),
                ("CODEX_SESSION_ID", Some("http-async-transfer-worker")),
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
                        "http-async-transfer",
                    )
                    .await;
                    let _ = post_session_join(
                        axum::extract::Path("http-async-transfer".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            capabilities: vec!["general".into()],
                            name: Some("Async Transfer Worker".into()),
                            project_dir: project_dir.to_string_lossy().into_owned(),
                            persona: None,
                        }),
                    )
                    .await;
                    let async_db = state.async_db.get().expect("async db");
                    let resolved = async_db
                        .resolve_session("http-async-transfer")
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

                    let response = post_transfer_leader(
                        axum::extract::Path("http-async-transfer".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(LeaderTransferRequest {
                            actor: "spoofed".into(),
                            new_leader_id: worker_id.clone(),
                            reason: Some("hand off".into()),
                        }),
                    )
                    .await;

                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(body["session"]["leader_id"].as_str(), Some("claude-leader"));
                    assert_eq!(
                        body["session"]["pending_leader_transfer"]["new_leader_id"].as_str(),
                        Some(worker_id.as_str())
                    );
                });
            },
        );
    });
}
