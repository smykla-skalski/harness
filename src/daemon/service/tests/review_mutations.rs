//! Async-path coverage for the review mutation wrappers on the daemon
//! service facade. Specifically proves that the async
//! `submit_for_review_async` variant honors the same `spawn_reviewer`
//! auto-emission contract as the file-backed sync path.

use crate::daemon::protocol::{
    TaskAssignRequest, TaskCreateRequest, TaskSubmitForReviewRequest, TaskUpdateRequest,
};
use crate::session::types::{SessionRole, TaskStatus};

use super::*;

#[test]
fn submit_for_review_async_emits_spawn_reviewer_when_no_reviewer_present() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("async-submit-review-worker"),
            || {
                let runtime_tokio = tokio::runtime::Runtime::new().expect("runtime");
                runtime_tokio.block_on(async {
                let db_path = project
                    .parent()
                    .expect("project parent")
                    .join("daemon.sqlite");
                let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db");

                let state = start_direct_session_async(
                    &async_db,
                    project,
                    "daemon-async-submit-review",
                    "async submit_for_review spawn",
                    "async review flow",
                    None,
                )
                .await;
                let leader_id = state.leader_id.clone().expect("leader id");
                let joined = join_session_direct_async(
                    "daemon-async-submit-review",
                    &crate::daemon::protocol::SessionJoinRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![],
                        name: None,
                        project_dir: project.to_string_lossy().into(),
                        persona: None,
                    },
                    &async_db,
                )
                .await
                .expect("join worker");
                let worker_id = joined
                    .agents
                    .keys()
                    .find(|id| id.starts_with("codex-"))
                    .expect("worker id")
                    .to_string();

                let created = create_task_async(
                    "daemon-async-submit-review",
                    &TaskCreateRequest {
                        actor: leader_id.clone(),
                        title: "review flow task".into(),
                        context: None,
                        severity: crate::session::types::TaskSeverity::Medium,
                        suggested_fix: None,
                    },
                    &async_db,
                )
                .await
                .expect("create task");
                let task_id = created.tasks[0].task_id.clone();

                assign_task_async(
                    "daemon-async-submit-review",
                    &task_id,
                    &TaskAssignRequest {
                        actor: leader_id.clone(),
                        agent_id: worker_id.clone(),
                    },
                    &async_db,
                None,
                )
                .await
                .expect("assign task");

                update_task_async(
                    "daemon-async-submit-review",
                    &task_id,
                    &TaskUpdateRequest {
                        actor: worker_id.clone(),
                        status: TaskStatus::InProgress,
                        note: None,
                    },
                    &async_db,
                None,
                )
                .await
                .expect("move task in_progress");

                submit_for_review_async(
                    "daemon-async-submit-review",
                    &task_id,
                    &TaskSubmitForReviewRequest {
                        actor: worker_id.clone(),
                        summary: None,
                        suggested_persona: None,
                    },
                    &async_db,
                )
                .await
                .expect("submit_for_review async");

                let resolved_after = async_db
                    .resolve_session("daemon-async-submit-review")
                    .await
                    .expect("resolve")
                    .expect("present");
                let leader_agent = resolved_after
                    .state
                    .agents
                    .get(&leader_id)
                    .expect("leader present");
                let leader_runtime = crate::agents::runtime::runtime_for_name(&leader_agent.runtime)
                    .expect("leader runtime");
                let leader_signal_session = leader_agent
                    .agent_session_id
                    .clone()
                    .unwrap_or_else(|| resolved_after.state.session_id.clone());
                let signal_dir = leader_runtime
                    .signal_dir(project, &leader_signal_session)
                    .join("pending");
                let entries: Vec<String> = std::fs::read_dir(&signal_dir)
                    .map(|iter| {
                        iter.filter_map(Result::ok)
                            .map(|e| e.file_name().to_string_lossy().into_owned())
                            .collect()
                    })
                    .unwrap_or_default();
                let has_spawn_reviewer = entries.iter().any(|name| {
                    let Ok(contents) = std::fs::read_to_string(signal_dir.join(name)) else {
                        return false;
                    };
                    contents.contains("spawn_reviewer")
                });
                assert!(
                    has_spawn_reviewer,
                    "async submit_for_review must materialize spawn_reviewer signal under {}; entries={entries:?}",
                    signal_dir.display(),
                );
            });
            },
        );
    });
}
