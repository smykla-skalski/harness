use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use fs_err as fs;
use tempfile::tempdir;

use crate::daemon::index;
use crate::daemon::protocol::SessionJoinRequest;
use crate::daemon::service::join_session_direct_async;
use crate::session::types::SessionRole;
use crate::session::{service as session_service, storage as session_storage};
use crate::workspace::project_context_dir;
use harness_testkit::with_isolated_harness_env;

use super::async_mutations::{
    init_git_project, start_async_http_session, test_http_state_with_empty_async_db,
};
use super::*;

fn append_project_ledger_entry(project_dir: &std::path::Path) {
    let ledger_path = project_context_dir(project_dir)
        .join("agents")
        .join("ledger")
        .join("events.jsonl");
    fs::create_dir_all(ledger_path.parent().expect("ledger dir")).expect("create ledger dir");
    fs::write(
        &ledger_path,
        format!(
            "{{\"sequence\":1,\"recorded_at\":\"2026-03-28T12:00:00Z\",\"cwd\":\"{}\"}}\n",
            project_dir.display()
        ),
    )
    .expect("write ledger");
}

fn write_agent_log(
    project_dir: &std::path::Path,
    runtime: &str,
    runtime_session_id: &str,
    text: &str,
) {
    let log_path = project_context_dir(project_dir)
        .join("agents/sessions")
        .join(runtime)
        .join(runtime_session_id)
        .join("raw.jsonl");
    fs::create_dir_all(log_path.parent().expect("log dir")).expect("create log dir");
    fs::write(
        log_path,
        format!(
            "{{\"timestamp\":\"2026-03-28T12:00:00Z\",\"message\":{{\"role\":\"assistant\",\"content\":\"{text}\"}}}}\n"
        ),
    )
    .expect("write leader log");
}

#[test]
fn post_observe_session_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("http-async-observe-leader")),
                ("CODEX_SESSION_ID", Some("http-async-observe-worker")),
            ],
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let project_dir = sandbox.path().join("project");
                    init_git_project(&project_dir);

                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let body =
                        start_async_http_session(state.clone(), &project_dir, "http-async-observe")
                            .await;
                    let leader_id = body["state"]["leader_id"]
                        .as_str()
                        .expect("leader id")
                        .to_string();
                    let joined = join_session_direct_async(
                        "http-async-observe",
                        &SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            capabilities: vec!["general".into()],
                            name: Some("HTTP Async Observe Worker".into()),
                            project_dir: project_dir.to_string_lossy().into_owned(),
                            persona: None,
                        },
                        state.async_db.get().expect("async db").as_ref(),
                    )
                    .await
                    .expect("join worker");
                    let worker_id = joined
                        .agents
                        .keys()
                        .find(|agent_id| agent_id.starts_with("codex-"))
                        .expect("worker id");
                    let worker_session_id = joined
                        .agents
                        .get(worker_id)
                        .and_then(|agent| agent.agent_session_id.clone())
                        .expect("worker runtime session id");
                    append_project_ledger_entry(&project_dir);
                    write_agent_log(
                        &project_dir,
                        "codex",
                        &worker_session_id,
                        "This is a harness infrastructure issue - the KDS port wasn't forwarded",
                    );

                    let response = post_observe_session(
                        Path("http-async-observe".to_string()),
                        auth_headers(),
                        State(state.clone()),
                        Some(Json(ObserveSessionRequest {
                            actor: Some(leader_id),
                        })),
                    )
                    .await;
                    let (status, body) = response_json(response).await;

                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(body["tasks"].as_array().map(Vec::len), Some(1),);
                });
            },
        );
    });
}

#[test]
fn post_observe_session_uses_sync_db_without_mutating_state_file() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("http-sync-observe-leader")),
                ("CODEX_SESSION_ID", Some("http-sync-observe-worker")),
            ],
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let state = session_service::start_session(
                    "http sync observe test",
                    "",
                    &project_dir,
                    Some("claude"),
                    Some("http-sync-observe"),
                )
                .expect("start session");
                let leader_id = state.leader_id.clone().expect("leader id");
                let joined = session_service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    &project_dir,
                    None,
                )
                .expect("join worker");
                let worker_id = joined
                    .agents
                    .keys()
                    .find(|agent_id| agent_id.starts_with("codex-"))
                    .expect("worker id")
                    .clone();
                let worker_session_id = joined
                    .agents
                    .get(&worker_id)
                    .and_then(|agent| agent.agent_session_id.clone())
                    .expect("worker runtime session id");
                append_project_ledger_entry(&project_dir);
                write_agent_log(
                    &project_dir,
                    "codex",
                    &worker_session_id,
                    "This is a harness infrastructure issue - the KDS port wasn't forwarded",
                );

                let db_path = sandbox.path().join("daemon-sync.sqlite");
                let http_state = test_http_state_with_sync_db_only(&db_path);
                let resolved =
                    index::resolve_session("http-sync-observe").expect("resolve session");
                {
                    let db = http_state
                        .db
                        .get()
                        .expect("db slot")
                        .lock()
                        .expect("db lock");
                    db.sync_project(&resolved.project).expect("sync project");
                    db.sync_session(&resolved.project.project_id, &resolved.state)
                        .expect("sync session");
                }

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let response = post_observe_session(
                        Path("http-sync-observe".to_string()),
                        auth_headers(),
                        State(http_state.clone()),
                        Some(Json(ObserveSessionRequest {
                            actor: Some(leader_id.clone()),
                        })),
                    )
                    .await;
                    let (status, body) = response_json(response).await;

                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(body["tasks"].as_array().map(Vec::len), Some(1));
                });

                let file_state = session_storage::load_state(&project_dir, "http-sync-observe")
                    .expect("load state")
                    .expect("file state");
                assert!(file_state.tasks.is_empty());

                let db = http_state
                    .db
                    .get()
                    .expect("db slot")
                    .lock()
                    .expect("db lock");
                let db_state = db
                    .load_session_state("http-sync-observe")
                    .expect("load db state")
                    .expect("db state");
                assert_eq!(db_state.tasks.len(), 1);
                assert_eq!(
                    db.load_conversation_events("http-sync-observe", &worker_id)
                        .expect("load worker transcript")
                        .len(),
                    1
                );
            },
        );
    });
}
