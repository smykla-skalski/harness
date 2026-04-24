//! Reviewer-requested coverage for Slice 3: after each real async review
//! mutation, the denormalized v10 columns on `tasks` must reflect the new
//! state. Reads the raw SQLite columns directly (not the serialized
//! `state.json` blob) to prove the sync and async write paths keep the
//! mirror in lock-step with the in-memory state.

use crate::daemon::protocol::{
    TaskArbitrateRequest, TaskAssignRequest, TaskClaimReviewRequest, TaskCreateRequest,
    TaskRespondReviewRequest, TaskSubmitForReviewRequest, TaskSubmitReviewRequest,
    TaskUpdateRequest,
};
use crate::session::types::{ReviewPoint, ReviewPointState, ReviewVerdict, SessionRole, TaskStatus};

use super::*;

#[test]
fn v10_task_columns_track_every_review_mutation_on_async_path() {
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
                "v10-col-track",
                "v10 column tracker",
                "review column mirror coverage",
                None,
            )
            .await;
            let leader_id = state.leader_id.clone().expect("leader id");
            let worker_id = temp_env::async_with_vars(
                [("CODEX_SESSION_ID", Some("v10-col-worker"))],
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
                [("GEMINI_SESSION_ID", Some("v10-col-gemini"))],
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
                [("CLAUDE_SESSION_ID", Some("v10-col-claude"))],
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
                    title: "v10 column coverage".into(),
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
                    actor: leader_id.clone(),
                    agent_id: worker_id.clone(),
                },
                &async_db,
            )
            .await
            .expect("assign");
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
            .expect("in_progress");

            // Baseline: freshly-created, non-reviewed task.
            let columns = async_db
                .fetch_task_v10_columns(&state.session_id, &task_id)
                .await
                .expect("fetch baseline")
                .expect("task row present");
            assert!(columns.awaiting_review_queued_at.is_none());
            assert!(columns.awaiting_review_submitter_agent_id.is_none());
            assert_eq!(columns.awaiting_review_required_consensus, 2);
            assert_eq!(columns.review_round, 0);
            assert!(columns.review_claim_json.is_none());
            assert!(columns.consensus_json.is_none());
            assert!(columns.arbitration_json.is_none());
            assert!(columns.suggested_persona.is_none());
            assert_eq!(columns.status, "inprogress");

            // After submit-for-review: awaiting columns + persona hint populated.
            submit_for_review_async(
                &state.session_id,
                &task_id,
                &TaskSubmitForReviewRequest {
                    actor: worker_id.clone(),
                    summary: Some("ready for review".into()),
                    suggested_persona: Some("code-reviewer".into()),
                },
                &async_db,
            )
            .await
            .expect("submit_for_review");
            let columns = async_db
                .fetch_task_v10_columns(&state.session_id, &task_id)
                .await
                .expect("fetch after submit_for_review")
                .expect("row");
            assert!(
                columns.awaiting_review_queued_at.is_some(),
                "awaiting_review_queued_at must be set after submit_for_review"
            );
            assert_eq!(
                columns.awaiting_review_submitter_agent_id.as_deref(),
                Some(worker_id.as_str())
            );
            assert_eq!(columns.status, "awaitingreview");
            assert_eq!(
                columns.suggested_persona.as_deref(),
                Some("code-reviewer"),
                "persona hint must round-trip into column"
            );
            assert_eq!(columns.review_round, 0);
            assert!(columns.review_claim_json.is_none());

            // After two claims: review_claim_json populated with both reviewers.
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
            let columns = async_db
                .fetch_task_v10_columns(&state.session_id, &task_id)
                .await
                .expect("fetch after claim")
                .expect("row");
            let claim_json = columns
                .review_claim_json
                .expect("review_claim_json set after claim");
            assert!(
                claim_json.contains(&reviewer_gemini),
                "claim json must record gemini reviewer: {claim_json}"
            );
            assert!(
                claim_json.contains(&reviewer_claude),
                "claim json must record claude reviewer: {claim_json}"
            );
            assert_eq!(columns.status, "inreview");

            // Round 1: both reviewers request_changes on p1 → consensus_json set,
            // review_round still 0 (respond-review bumps the counter).
            let points = vec![ReviewPoint {
                point_id: "p1".into(),
                text: "fix this".into(),
                state: ReviewPointState::Open,
                worker_note: None,
            }];
            for reviewer in [&reviewer_gemini, &reviewer_claude] {
                submit_review_async(
                    &state.session_id,
                    &task_id,
                    &TaskSubmitReviewRequest {
                        actor: reviewer.clone(),
                        verdict: ReviewVerdict::RequestChanges,
                        summary: "round 1".into(),
                        points: points.clone(),
                    },
                    &async_db,
                )
                .await
                .expect("round 1 submit");
            }
            let columns = async_db
                .fetch_task_v10_columns(&state.session_id, &task_id)
                .await
                .expect("fetch after round 1")
                .expect("row");
            let consensus_json = columns
                .consensus_json
                .expect("consensus_json populated after quorum");
            assert!(
                consensus_json.contains("request_changes"),
                "consensus verdict must be request_changes: {consensus_json}"
            );
            assert_eq!(columns.review_round, 0);

            // Respond-review with disputed point: review_round increments, consensus
            // is archived to history (column clears), status flips back to awaiting.
            respond_review_async(
                &state.session_id,
                &task_id,
                &TaskRespondReviewRequest {
                    actor: worker_id.clone(),
                    agreed: vec![],
                    disputed: vec!["p1".into()],
                    note: Some("disputing p1".into()),
                },
                &async_db,
            )
            .await
            .expect("respond round 1");
            let columns = async_db
                .fetch_task_v10_columns(&state.session_id, &task_id)
                .await
                .expect("fetch after respond")
                .expect("row");
            assert_eq!(columns.review_round, 1, "respond must bump counter to 1");
            assert!(
                columns.consensus_json.is_none(),
                "consensus_json must clear after worker rework"
            );

            // Round 2: reviewers resubmit (claim persists when dispute keeps
            // task in review with a non-arbitration round).
            for reviewer in [&reviewer_gemini, &reviewer_claude] {
                submit_review_async(
                    &state.session_id,
                    &task_id,
                    &TaskSubmitReviewRequest {
                        actor: reviewer.clone(),
                        verdict: ReviewVerdict::RequestChanges,
                        summary: "round 2".into(),
                        points: points.clone(),
                    },
                    &async_db,
                )
                .await
                .expect("round 2 submit");
            }
            respond_review_async(
                &state.session_id,
                &task_id,
                &TaskRespondReviewRequest {
                    actor: worker_id.clone(),
                    agreed: vec![],
                    disputed: vec!["p1".into()],
                    note: None,
                },
                &async_db,
            )
            .await
            .expect("respond round 2");

            // Round 3: final pair of request_changes to arm arbitration.
            for reviewer in [&reviewer_gemini, &reviewer_claude] {
                submit_review_async(
                    &state.session_id,
                    &task_id,
                    &TaskSubmitReviewRequest {
                        actor: reviewer.clone(),
                        verdict: ReviewVerdict::RequestChanges,
                        summary: "round 3".into(),
                        points: points.clone(),
                    },
                    &async_db,
                )
                .await
                .expect("round 3 submit");
            }
            respond_review_async(
                &state.session_id,
                &task_id,
                &TaskRespondReviewRequest {
                    actor: worker_id.clone(),
                    agreed: vec![],
                    disputed: vec!["p1".into()],
                    note: None,
                },
                &async_db,
            )
            .await
            .expect("respond round 3");
            let columns = async_db
                .fetch_task_v10_columns(&state.session_id, &task_id)
                .await
                .expect("fetch pre-arbitration")
                .expect("row");
            assert_eq!(
                columns.review_round, 3,
                "three rounds of respond must land review_round at 3"
            );
            assert!(columns.arbitration_json.is_none());

            // Arbitrate: leader approves → arbitration_json set, status done.
            arbitrate_review_async(
                &state.session_id,
                &task_id,
                &TaskArbitrateRequest {
                    actor: leader_id,
                    verdict: ReviewVerdict::Approve,
                    summary: "shipping".into(),
                },
                &async_db,
            )
            .await
            .expect("arbitrate");
            let columns = async_db
                .fetch_task_v10_columns(&state.session_id, &task_id)
                .await
                .expect("fetch post-arbitration")
                .expect("row");
            let arbitration_json = columns
                .arbitration_json
                .expect("arbitration_json set after leader verdict");
            assert!(
                arbitration_json.contains("approve"),
                "arbitration verdict must be approve: {arbitration_json}"
            );
            assert!(
                arbitration_json.contains("shipping"),
                "arbitration summary must round-trip: {arbitration_json}"
            );
            assert_eq!(columns.status, "done");
        });
    });
}
