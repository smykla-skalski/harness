use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use tempfile::tempdir;

use crate::daemon::protocol::{
    SessionJoinRequest, SessionStartRequest, TaskAssignRequest, TaskCreateRequest,
    TaskSubmitForReviewRequest, TaskUpdateRequest,
};
use crate::daemon::service::{
    assign_task_async, create_task_async, join_session_direct_async, start_session_direct_async,
    update_task_async,
};
use crate::session::types::{SessionRole, TaskSeverity, TaskStatus};
use harness_testkit::{init_git_repo_with_seed, with_isolated_harness_env};

use super::*;
use super::super::tasks::post_task_submit_for_review;

#[test]
fn post_task_submit_for_review_accepts_worker_actor() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let project = tmp.path().join("project");
        init_git_repo_with_seed(&project);

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state = test_http_state_with_db();
            let async_db = state.async_db.get().expect("async db").clone();
            let session_id = "sess-http-submit-review";

            let started = start_session_direct_async(
                &SessionStartRequest {
                    title: "http submit".into(),
                    context: "http submit review".into(),
                    session_id: Some(session_id.into()),
                    project_dir: project.to_string_lossy().into_owned(),
                    policy_preset: None,
                    base_ref: None,
                },
                async_db.as_ref(),
            )
            .await
            .expect("start session");

            let led = join_session_direct_async(
                &started.session_id,
                &SessionJoinRequest {
                    runtime: "claude".into(),
                    role: SessionRole::Leader,
                    fallback_role: None,
                    capabilities: vec![],
                    name: Some("leader".into()),
                    project_dir: project.to_string_lossy().into_owned(),
                    persona: None,
                },
                async_db.as_ref(),
            )
            .await
            .expect("join leader");
            let leader_id = led.leader_id.clone().expect("leader id");

            let joined = join_session_direct_async(
                &started.session_id,
                &SessionJoinRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    fallback_role: None,
                    capabilities: vec![],
                    name: Some("worker".into()),
                    project_dir: project.to_string_lossy().into_owned(),
                    persona: None,
                },
                async_db.as_ref(),
            )
            .await
            .expect("join worker");
            let worker_id = joined
                .agents
                .iter()
                .find(|(_, agent)| agent.runtime == "codex")
                .map(|(agent_id, _)| agent_id.clone())
                .expect("codex worker id");

            let created = create_task_async(
                &started.session_id,
                &TaskCreateRequest {
                    actor: leader_id.clone(),
                    title: "review me".into(),
                    context: None,
                    severity: TaskSeverity::Medium,
                    suggested_fix: None,
                },
                async_db.as_ref(),
            )
            .await
            .expect("create task");
            let task_id = created.tasks[0].task_id.clone();

            assign_task_async(
                &started.session_id,
                &task_id,
                &TaskAssignRequest {
                    actor: leader_id,
                    agent_id: worker_id.clone(),
                },
                async_db.as_ref(),
            )
            .await
            .expect("assign task");
            update_task_async(
                &started.session_id,
                &task_id,
                &TaskUpdateRequest {
                    actor: worker_id.clone(),
                    status: TaskStatus::InProgress,
                    note: None,
                },
                async_db.as_ref(),
            )
            .await
            .expect("move task in progress");

            let response = post_task_submit_for_review(
                Path((started.session_id.clone(), task_id.clone())),
                auth_headers(),
                State(state.clone()),
                Json(TaskSubmitForReviewRequest {
                    actor: worker_id.clone(),
                    summary: Some("ready".into()),
                    suggested_persona: None,
                }),
            )
            .await;
            let (status, body) = response_json(response).await;

            assert_eq!(
                status,
                StatusCode::OK,
                "submit-for-review should preserve worker actor: {body}"
            );

            let resolved = async_db
                .resolve_session(&started.session_id)
                .await
                .expect("resolve session")
                .expect("session present");
            let task = resolved
                .state
                .tasks
                .get(&task_id)
                .expect("task present after submit");
            assert_eq!(task.status, TaskStatus::AwaitingReview);
            assert_eq!(
                task.awaiting_review
                    .as_ref()
                    .map(|awaiting| awaiting.submitter_agent_id.as_str()),
                Some(worker_id.as_str())
            );
        });
    });
}
