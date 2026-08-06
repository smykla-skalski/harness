use super::*;
use crate::daemon::db::prelude::*;
use crate::daemon::http::core::post_agent_workspace_member_remove;
use crate::daemon::http::sessions::post_session_archive;
use crate::daemon::protocol::SessionArchiveRequest;

#[test]
fn delete_session_removes_worktree_and_returns_204() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                (
                    "CLAUDE_SESSION_ID",
                    Some("079ad5ae-c9ee-525b-8263-b9ec8b02155a"),
                ),
                (
                    "CODEX_SESSION_ID",
                    Some("079ad5ae-c9ee-525b-8263-b9ec8b02155a-worker"),
                ),
            ],
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    const SESSION_ID: &str = "a3421878-b3c4-566f-8d47-b103f3334ae1";
                    let body =
                        start_async_http_session(state.clone(), &project_dir, SESSION_ID).await;
                    let worker_id =
                        join_http_worker(&state, SESSION_ID, &project_dir, "Deletion Worker").await;
                    let worktree_path: std::path::PathBuf = body["state"]["worktree_path"]
                        .as_str()
                        .expect("worktree_path in response")
                        .into();
                    assert!(worktree_path.exists(), "worktree must exist before delete");

                    let response = delete_session(
                        axum::extract::Path(SESSION_ID.to_owned()),
                        auth_headers(),
                        State(state.clone()),
                    )
                    .await;
                    assert_eq!(response.status(), StatusCode::NO_CONTENT);
                    assert!(
                        !worktree_path.exists(),
                        "worktree must be gone after delete"
                    );

                    let async_db = state.async_db.get().expect("async db");
                    let resolved = async_db
                        .resolve_session(SESSION_ID)
                        .await
                        .expect("query ok");
                    assert!(resolved.is_none(), "session must be deleted from DB");
                    let durable_members = sqlx::query_scalar::<_, i64>(
                        "SELECT COUNT(*) FROM agent_workspace_member_provenance
                         WHERE source_session_id = ?1 AND source_agent_id = ?2",
                    )
                    .bind(SESSION_ID)
                    .bind(&worker_id)
                    .fetch_one(async_db.pool())
                    .await
                    .expect("count durable members after Session deletion");
                    assert_eq!(durable_members, 1);

                    let (workspace_id, member_id, runtime_lifecycle) =
                        sqlx::query_as::<_, (String, String, String)>(
                            "SELECT workspace_id, member_id, runtime_lifecycle
                             FROM agent_workspace_members
                             WHERE workspace_id IN (
                                 SELECT workspace_id FROM agent_workspace_member_provenance
                                 WHERE source_session_id = ?1 AND source_agent_id = ?2
                             )",
                        )
                        .bind(SESSION_ID)
                        .bind(&worker_id)
                        .fetch_one(async_db.pool())
                        .await
                        .expect("load detached durable member");
                    let response = post_agent_workspace_member_remove(
                        auth_headers(),
                        axum::extract::Path((workspace_id, member_id)),
                        State(state.clone()),
                        Json(AgentRemoveRequest {
                            actor: "test-operator".into(),
                        }),
                    )
                    .await;
                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK, "unexpected body: {body}");
                    let member = &body["team"]["members"][0];
                    assert_eq!(member["membership_status"], "removed");
                    assert_eq!(member["runtime_lifecycle"], runtime_lifecycle);
                });
            },
        );
    });
}

#[test]
fn delete_session_ignores_another_daemon_projection() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("delete-multi-daemon-worker"),
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let session_id = "9b23c386-7a8d-51df-a5b4-498980adf3dc";
                    start_async_http_session(state.clone(), &project_dir, session_id).await;
                    let async_db = state.async_db.get().expect("async db");
                    let other_workspace_id = async_db
                        .reconcile_agent_workspaces("daemon-delete-test-other")
                        .await
                        .expect("create another daemon projection")
                        .workspaces[0]
                        .workspace_id
                        .clone();
                    async_db
                        .reconcile_agent_workspace_team(
                            "daemon-delete-test-other",
                            &other_workspace_id,
                        )
                        .await
                        .expect("create another daemon team");

                    let response = delete_session(
                        axum::extract::Path(session_id.to_owned()),
                        auth_headers(),
                        State(state.clone()),
                    )
                    .await;
                    assert_eq!(response.status(), StatusCode::NO_CONTENT);
                    assert!(
                        async_db
                            .load_session_state(session_id)
                            .await
                            .expect("load deleted Session")
                            .is_none()
                    );
                });
            },
        );
    });
}

#[test]
fn delete_session_keeps_worktree_when_database_guard_rejects_deletion() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("delete-guard-rejection-worker"),
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let session_id = "e5e8b401-a97c-5888-8e73-0832c13ef8e0";
                    let body =
                        start_async_http_session(state.clone(), &project_dir, session_id).await;
                    let worktree_path: std::path::PathBuf = body["state"]["worktree_path"]
                        .as_str()
                        .expect("worktree path")
                        .into();
                    let async_db = state.async_db.get().expect("async db");
                    sqlx::query(
                        "CREATE TRIGGER reject_test_session_delete
                         BEFORE DELETE ON sessions
                         WHEN OLD.session_id = 'e5e8b401-a97c-5888-8e73-0832c13ef8e0'
                         BEGIN
                             SELECT RAISE(ABORT, 'forced deletion guard rejection');
                         END",
                    )
                    .execute(async_db.pool())
                    .await
                    .expect("install deletion guard");

                    let response = delete_session(
                        axum::extract::Path(session_id.to_owned()),
                        auth_headers(),
                        State(state.clone()),
                    )
                    .await;
                    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
                    assert!(
                        worktree_path.exists(),
                        "guard rejection must preserve worktree"
                    );
                    assert!(
                        async_db
                            .load_session_state(session_id)
                            .await
                            .expect("load protected Session")
                            .is_some(),
                        "guard rejection must preserve Session row"
                    );
                });
            },
        );
    });
}

#[test]
fn delete_session_removes_archived_session_and_returns_204() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("c5f25eba-6a40-528a-bfce-bc95d31b5aa1"),
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let session_id = "e3c5e42d-cf97-5104-b49e-d6e456d53f4c";
                    let body =
                        start_async_http_session(state.clone(), &project_dir, session_id).await;
                    let worktree_path: std::path::PathBuf = body["state"]["worktree_path"]
                        .as_str()
                        .expect("worktree_path in response")
                        .into();
                    let archived = post_session_archive(
                        axum::extract::Path(session_id.to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SessionArchiveRequest {
                            actor: "test-operator".into(),
                        }),
                    )
                    .await;
                    assert_eq!(archived.status(), StatusCode::OK);

                    let response = delete_session(
                        axum::extract::Path(session_id.to_owned()),
                        auth_headers(),
                        State(state.clone()),
                    )
                    .await;
                    assert_eq!(response.status(), StatusCode::NO_CONTENT);
                    assert!(
                        !worktree_path.exists(),
                        "archived worktree must be gone after delete"
                    );
                    let async_db = state.async_db.get().expect("async db");
                    assert!(
                        async_db
                            .load_session_state(session_id)
                            .await
                            .expect("load session state")
                            .is_none(),
                        "archived session must be deleted from DB"
                    );
                });
            },
        );
    });
}
