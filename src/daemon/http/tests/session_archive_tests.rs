use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use tempfile::tempdir;

use crate::daemon::http::sessions::{get_sessions, post_session_archive};
use crate::daemon::protocol::SessionArchiveRequest;
use harness_testkit::with_isolated_harness_env;

use super::async_mutations::{init_git_project, start_async_http_session, test_http_state_with_empty_async_db};
use super::*;

#[test]
fn post_session_archive_uses_async_db_and_hides_session_from_later_reads() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("http-async-archive-leader"),
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let session_id = "http-async-archive";
                    let _ = start_async_http_session(state.clone(), &project_dir, session_id).await;

                    let archived = post_session_archive(
                        axum::extract::Path(session_id.to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SessionArchiveRequest {
                            actor: "spoofed".into(),
                        }),
                    )
                    .await;
                    let (status, body) = response_json(archived).await;
                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(body["session_id"].as_str(), Some(session_id));
                    assert!(body["archived_at"].as_str().is_some());

                    let sessions = get_sessions(auth_headers(), State(state.clone())).await;
                    let (status, body) = response_json(sessions).await;
                    assert_eq!(status, StatusCode::OK);
                    assert!(
                        body.as_array()
                            .expect("session summaries")
                            .iter()
                            .all(|summary| summary["session_id"].as_str() != Some(session_id))
                    );

                    let async_db = state.async_db.get().expect("async db");
                    assert!(
                        async_db
                            .resolve_session(session_id)
                            .await
                            .expect("resolve session")
                            .is_none(),
                        "archived sessions must no longer resolve from async db reads"
                    );
                });
            },
        );
    });
}
