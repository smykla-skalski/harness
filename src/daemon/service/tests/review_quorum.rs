use crate::daemon::protocol::{
    TaskAssignRequest, TaskClaimReviewRequest, TaskCreateRequest, TaskSubmitForReviewRequest,
    TaskSubmitReviewRequest, TaskUpdateRequest,
};
use crate::session::types::{ReviewVerdict, SessionRole, TaskStatus};

use super::*;

#[test]
fn submit_review_async_concurrent_reviewers_close_quorum_without_lost_state() {
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
                "daemon-async-submit-review-quorum",
                "async submit_review quorum",
                "async review flow",
                None,
            )
            .await;
            let leader_id = state.leader_id.clone().expect("leader id");
            let worker_id = temp_env::async_with_vars(
                [("CODEX_SESSION_ID", Some("async-review-worker"))],
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
            let reviewer_gemini = temp_env::async_with_vars(
                [("GEMINI_SESSION_ID", Some("async-review-gemini"))],
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
                    .expect("join gemini reviewer");
                    joined
                        .agents
                        .values()
                        .find(|agent| {
                            agent.role == SessionRole::Reviewer && agent.runtime == "gemini"
                        })
                        .expect("gemini reviewer")
                        .agent_id
                        .clone()
                },
            )
            .await;
            let reviewer_claude = temp_env::async_with_vars(
                [("CLAUDE_SESSION_ID", Some("async-review-claude"))],
                async {
                    let joined = join_session_direct_async(
                        &state.session_id,
                        &crate::daemon::protocol::SessionJoinRequest {
                            runtime: "claude".into(),
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
                    .expect("join claude reviewer");
                    joined
                        .agents
                        .values()
                        .find(|agent| {
                            agent.role == SessionRole::Reviewer && agent.runtime == "claude"
                        })
                        .expect("claude reviewer")
                        .agent_id
                        .clone()
                },
            )
            .await;

            let created = create_task_async(
                &state.session_id,
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
            .expect("submit_for_review async");
            claim_review_async(
                &state.session_id,
                &task_id,
                &TaskClaimReviewRequest {
                    actor: reviewer_gemini.clone(),
                },
                &async_db,
            )
            .await
            .expect("gemini claim");
            claim_review_async(
                &state.session_id,
                &task_id,
                &TaskClaimReviewRequest {
                    actor: reviewer_claude.clone(),
                },
                &async_db,
            )
            .await
            .expect("claude claim");

            let gemini_request = TaskSubmitReviewRequest {
                actor: reviewer_gemini,
                verdict: ReviewVerdict::Approve,
                summary: "approve from gemini".into(),
                points: Vec::new(),
            };
            let claude_request = TaskSubmitReviewRequest {
                actor: reviewer_claude,
                verdict: ReviewVerdict::Approve,
                summary: "approve from claude".into(),
                points: Vec::new(),
            };
            let (gemini, claude) = tokio::join!(
                submit_review_async(&state.session_id, &task_id, &gemini_request, &async_db),
                submit_review_async(&state.session_id, &task_id, &claude_request, &async_db)
            );
            gemini.expect("gemini submit");
            claude.expect("claude submit");

            let resolved_after = async_db
                .resolve_session(&state.session_id)
                .await
                .expect("resolve")
                .expect("present");
            let task = resolved_after.state.tasks.get(&task_id).expect("task");
            assert_eq!(task.status, TaskStatus::Done);
            let consensus = task.consensus.as_ref().expect("consensus");
            assert_eq!(consensus.verdict, ReviewVerdict::Approve);
            assert_eq!(consensus.reviewer_agent_ids.len(), 2);
        });
    });
}
