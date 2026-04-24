//! F2: proves `submit_review`/`submit_review_async` inserts into the
//! `task_reviews` mirror immediately, without a daemon restart or
//! `rebuild_task_reviews` resync.

use crate::daemon::protocol::{
    TaskAssignRequest, TaskClaimReviewRequest, TaskCreateRequest, TaskSubmitForReviewRequest,
    TaskSubmitReviewRequest, TaskUpdateRequest,
};
use crate::session::types::{ReviewVerdict, SessionRole, TaskStatus};

use super::*;

#[test]
fn submit_review_async_writes_task_reviews_row_without_rebuild() {
    with_temp_project(|project| {
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
                "daemon-review-persistence",
                "submit_review mirror",
                "review persistence flow",
                None,
            )
            .await;
            let leader_id = state.leader_id.clone().expect("leader id");
            let worker_id = temp_env::async_with_vars(
                [("CODEX_SESSION_ID", Some("persistence-worker"))],
                async {
                    let joined = join_session_direct_async(
                        &state.session_id,
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
                    joined
                        .agents
                        .values()
                        .find(|agent| agent.role == SessionRole::Worker)
                        .expect("worker")
                        .agent_id
                        .clone()
                },
            )
            .await;
            let reviewer_id = temp_env::async_with_vars(
                [("GEMINI_SESSION_ID", Some("persistence-gemini"))],
                async {
                    let joined = join_session_direct_async(
                        &state.session_id,
                        &crate::daemon::protocol::SessionJoinRequest {
                            runtime: "gemini".into(),
                            role: SessionRole::Reviewer,
                            fallback_role: None,
                            capabilities: vec![],
                            name: None,
                            project_dir: project.to_string_lossy().into(),
                            persona: None,
                        },
                        &async_db,
                    )
                    .await
                    .expect("join reviewer");
                    joined
                        .agents
                        .values()
                        .find(|agent| agent.role == SessionRole::Reviewer)
                        .expect("reviewer")
                        .agent_id
                        .clone()
                },
            )
            .await;

            let created = create_task_async(
                &state.session_id,
                &TaskCreateRequest {
                    actor: leader_id.clone(),
                    title: "mirror review row".into(),
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
                &state.session_id,
                &task_id,
                &TaskAssignRequest {
                    actor: leader_id,
                    agent_id: worker_id.clone(),
                },
                &async_db,
            )
            .await
            .expect("assign task");
            update_task_async(
                &state.session_id,
                &task_id,
                &TaskUpdateRequest {
                    actor: worker_id.clone(),
                    status: TaskStatus::InProgress,
                    note: None,
                },
                &async_db,
            )
            .await
            .expect("move task in_progress");
            submit_for_review_async(
                &state.session_id,
                &task_id,
                &TaskSubmitForReviewRequest {
                    actor: worker_id,
                    summary: None,
                    suggested_persona: None,
                },
                &async_db,
            )
            .await
            .expect("submit_for_review");
            claim_review_async(
                &state.session_id,
                &task_id,
                &TaskClaimReviewRequest {
                    actor: reviewer_id.clone(),
                },
                &async_db,
            )
            .await
            .expect("claim");

            // Pre-submit: mirror table empty.
            assert_eq!(
                async_db
                    .count_task_reviews(&state.session_id, &task_id)
                    .await
                    .expect("count pre"),
                0,
                "task_reviews mirror must be empty before first submit_review"
            );

            submit_review_async(
                &state.session_id,
                &task_id,
                &TaskSubmitReviewRequest {
                    actor: reviewer_id,
                    verdict: ReviewVerdict::Approve,
                    summary: "approve via mirror test".into(),
                    points: Vec::new(),
                },
                &async_db,
            )
            .await
            .expect("submit_review");

            // Post-submit: row is visible in SQLite without any restart/resync/rebuild.
            assert_eq!(
                async_db
                    .count_task_reviews(&state.session_id, &task_id)
                    .await
                    .expect("count post"),
                1,
                "submit_review_async must insert into task_reviews immediately"
            );
        });
    });
}
