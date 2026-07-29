use super::*;

#[test]
fn delete_session_removes_worktree_and_returns_204() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("079ad5ae-c9ee-525b-8263-b9ec8b02155a"),
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let body = start_async_http_session(
                        state.clone(),
                        &project_dir,
                        "a3421878-b3c4-566f-8d47-b103f3334ae1",
                    )
                    .await;
                    let worktree_path: std::path::PathBuf = body["state"]["worktree_path"]
                        .as_str()
                        .expect("worktree_path in response")
                        .into();
                    assert!(worktree_path.exists(), "worktree must exist before delete");

                    let response = delete_session(
                        axum::extract::Path("a3421878-b3c4-566f-8d47-b103f3334ae1".to_owned()),
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
                        .resolve_session("a3421878-b3c4-566f-8d47-b103f3334ae1")
                        .await
                        .expect("query ok");
                    assert!(resolved.is_none(), "session must be deleted from DB");
                });
            },
        );
    });
}
