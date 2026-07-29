//! Reviewer-requested coverage for Slice 3: after each real async review
//! mutation, the denormalized v10 columns on `tasks` must reflect the new
//! state. Reads the raw `SQLite` columns directly (not the serialized
//! `state.json` blob) to prove the sync and async write paths keep the
//! mirror in lock-step with the in-memory state.

use std::path::Path;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    TaskArbitrateRequest, TaskAssignRequest, TaskClaimReviewRequest, TaskCreateRequest,
    TaskRespondReviewRequest, TaskSubmitForReviewRequest, TaskSubmitReviewRequest,
    TaskUpdateRequest,
};
use crate::session::types::{
    ReviewPoint, ReviewPointState, ReviewVerdict, SessionRole, TaskStatus,
};

use super::*;

#[test]
fn v10_task_columns_track_every_review_mutation_on_async_path() {
    with_temp_project(|project| {
        let runtime_tokio = tokio::runtime::Runtime::new().expect("runtime");
        runtime_tokio.block_on(async {
            let fixture = v10_columns_setup(project).await;
            v10_columns_assert_baseline(&fixture).await;
            v10_columns_submit_for_review(&fixture).await;
            v10_columns_claim_review(&fixture).await;
            let points = v10_columns_round_one(&fixture).await;
            v10_columns_respond_round_one(&fixture).await;
            v10_columns_round_two(&fixture, &points).await;
            v10_columns_round_three(&fixture, &points).await;
            v10_columns_arbitrate(&fixture).await;
        });
    });
}

// Everything the review-lifecycle phase helpers below need: a fresh async
// database, a leader/worker/two-reviewer session, and one in-progress task.
struct V10ColumnsFixture {
    async_db: AsyncDaemonDb,
    session_id: String,
    task_id: String,
    leader_id: String,
    worker_id: String,
    reviewer_gemini: String,
    reviewer_claude: String,
}

// Joins one agent under an isolated runtime session id and returns its
// agent_id; `role`/`runtime` double as the lookup key since each runtime
// only ever joins once per fixture.
async fn v10_columns_join_agent(
    async_db: &AsyncDaemonDb,
    project: &Path,
    session_id: &str,
    env_var: &'static str,
    env_value: &'static str,
    runtime: &str,
    role: SessionRole,
) -> String {
    temp_env::async_with_vars([(env_var, Some(env_value))], async {
        let joined = join_session_direct_async(
            session_id,
            &crate::daemon::protocol::SessionJoinRequest {
                runtime: runtime.into(),
                role,
                fallback_role: None,
                capabilities: vec![],
                name: None,
                project_dir: project.to_string_lossy().into(),
                persona: None,
            },
            async_db,
        )
        .await
        .expect("join agent");
        joined
            .agents
            .values()
            .find(|agent| agent.role == role && agent.runtime == runtime)
            .expect("joined agent present")
            .agent_id
            .clone()
    })
    .await
}

async fn v10_columns_setup(project: &Path) -> V10ColumnsFixture {
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
        "915a83ca-dc2d-56ae-b215-da5aa70a022d",
        "v10 column tracker",
        "review column mirror coverage",
        None,
    )
    .await;
    let leader_id = state.leader_id.clone().expect("leader id");
    let worker_id = v10_columns_join_agent(
        &async_db,
        project,
        &state.session_id,
        "CODEX_SESSION_ID",
        "v10-col-worker",
        "codex",
        SessionRole::Worker,
    )
    .await;
    let reviewer_gemini = v10_columns_join_agent(
        &async_db,
        project,
        &state.session_id,
        "GEMINI_SESSION_ID",
        "v10-col-gemini",
        "gemini",
        SessionRole::Reviewer,
    )
    .await;
    let reviewer_claude = v10_columns_join_agent(
        &async_db,
        project,
        &state.session_id,
        "CLAUDE_SESSION_ID",
        "v10-col-claude",
        "claude",
        SessionRole::Reviewer,
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
        crate::daemon::service::WakeDispatch::none(),
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
        crate::daemon::service::WakeDispatch::none(),
    )
    .await
    .expect("in_progress");

    V10ColumnsFixture {
        async_db,
        session_id: state.session_id,
        task_id,
        leader_id,
        worker_id,
        reviewer_gemini,
        reviewer_claude,
    }
}

// Freshly-created, non-reviewed task.
async fn v10_columns_assert_baseline(fixture: &V10ColumnsFixture) {
    let columns = fixture
        .async_db
        .fetch_task_v10_columns(&fixture.session_id, &fixture.task_id)
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
}

// After submit-for-review: awaiting columns + persona hint populated.
async fn v10_columns_submit_for_review(fixture: &V10ColumnsFixture) {
    submit_for_review_async(
        &fixture.session_id,
        &fixture.task_id,
        &TaskSubmitForReviewRequest {
            actor: fixture.worker_id.clone(),
            summary: Some("ready for review".into()),
            suggested_persona: Some("code-reviewer".into()),
        },
        &fixture.async_db,
    )
    .await
    .expect("submit_for_review");
    let columns = fixture
        .async_db
        .fetch_task_v10_columns(&fixture.session_id, &fixture.task_id)
        .await
        .expect("fetch after submit_for_review")
        .expect("row");
    assert!(
        columns.awaiting_review_queued_at.is_some(),
        "awaiting_review_queued_at must be set after submit_for_review"
    );
    assert_eq!(
        columns.awaiting_review_submitter_agent_id.as_deref(),
        Some(fixture.worker_id.as_str())
    );
    assert_eq!(columns.status, "awaitingreview");
    assert_eq!(
        columns.suggested_persona.as_deref(),
        Some("code-reviewer"),
        "persona hint must round-trip into column"
    );
    assert_eq!(columns.review_round, 0);
    assert!(columns.review_claim_json.is_none());
}

// After two claims: review_claim_json populated with both reviewers.
async fn v10_columns_claim_review(fixture: &V10ColumnsFixture) {
    claim_review_async(
        &fixture.session_id,
        &fixture.task_id,
        &TaskClaimReviewRequest {
            actor: fixture.reviewer_gemini.clone(),
        },
        &fixture.async_db,
    )
    .await
    .expect("gemini claim");
    claim_review_async(
        &fixture.session_id,
        &fixture.task_id,
        &TaskClaimReviewRequest {
            actor: fixture.reviewer_claude.clone(),
        },
        &fixture.async_db,
    )
    .await
    .expect("claude claim");
    let columns = fixture
        .async_db
        .fetch_task_v10_columns(&fixture.session_id, &fixture.task_id)
        .await
        .expect("fetch after claim")
        .expect("row");
    let claim_json = columns
        .review_claim_json
        .expect("review_claim_json set after claim");
    assert!(
        claim_json.contains(&fixture.reviewer_gemini),
        "claim json must record gemini reviewer: {claim_json}"
    );
    assert!(
        claim_json.contains(&fixture.reviewer_claude),
        "claim json must record claude reviewer: {claim_json}"
    );
    assert_eq!(columns.status, "inreview");
}

// Round 1: both reviewers request_changes on p1 -> consensus_json set,
// review_round still 0 (respond-review bumps the counter). Returns the
// review points list rounds 2 and 3 reuse.
async fn v10_columns_round_one(fixture: &V10ColumnsFixture) -> Vec<ReviewPoint> {
    let points = vec![ReviewPoint {
        point_id: "p1".into(),
        text: "fix this".into(),
        state: ReviewPointState::Open,
        worker_note: None,
    }];
    for reviewer in [&fixture.reviewer_gemini, &fixture.reviewer_claude] {
        submit_review_async(
            &fixture.session_id,
            &fixture.task_id,
            &TaskSubmitReviewRequest {
                actor: reviewer.clone(),
                verdict: ReviewVerdict::RequestChanges,
                summary: "round 1".into(),
                points: points.clone(),
            },
            &fixture.async_db,
        )
        .await
        .expect("round 1 submit");
    }
    let columns = fixture
        .async_db
        .fetch_task_v10_columns(&fixture.session_id, &fixture.task_id)
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
    points
}

// Respond-review with disputed point: review_round increments, consensus
// is archived to history (column clears), status flips back to awaiting.
async fn v10_columns_respond_round_one(fixture: &V10ColumnsFixture) {
    respond_review_async(
        &fixture.session_id,
        &fixture.task_id,
        &TaskRespondReviewRequest {
            actor: fixture.worker_id.clone(),
            agreed: vec![],
            disputed: vec!["p1".into()],
            note: Some("disputing p1".into()),
        },
        &fixture.async_db,
    )
    .await
    .expect("respond round 1");
    let columns = fixture
        .async_db
        .fetch_task_v10_columns(&fixture.session_id, &fixture.task_id)
        .await
        .expect("fetch after respond")
        .expect("row");
    assert_eq!(columns.review_round, 1, "respond must bump counter to 1");
    assert!(
        columns.consensus_json.is_none(),
        "consensus_json must clear after worker rework"
    );
}

// Round 2: reviewers resubmit (claim persists when dispute keeps the task
// in review with a non-arbitration round).
async fn v10_columns_round_two(fixture: &V10ColumnsFixture, points: &[ReviewPoint]) {
    for reviewer in [&fixture.reviewer_gemini, &fixture.reviewer_claude] {
        submit_review_async(
            &fixture.session_id,
            &fixture.task_id,
            &TaskSubmitReviewRequest {
                actor: reviewer.clone(),
                verdict: ReviewVerdict::RequestChanges,
                summary: "round 2".into(),
                points: points.to_vec(),
            },
            &fixture.async_db,
        )
        .await
        .expect("round 2 submit");
    }
    respond_review_async(
        &fixture.session_id,
        &fixture.task_id,
        &TaskRespondReviewRequest {
            actor: fixture.worker_id.clone(),
            agreed: vec![],
            disputed: vec!["p1".into()],
            note: None,
        },
        &fixture.async_db,
    )
    .await
    .expect("respond round 2");
}

// Round 3: final pair of request_changes to arm arbitration.
async fn v10_columns_round_three(fixture: &V10ColumnsFixture, points: &[ReviewPoint]) {
    for reviewer in [&fixture.reviewer_gemini, &fixture.reviewer_claude] {
        submit_review_async(
            &fixture.session_id,
            &fixture.task_id,
            &TaskSubmitReviewRequest {
                actor: reviewer.clone(),
                verdict: ReviewVerdict::RequestChanges,
                summary: "round 3".into(),
                points: points.to_vec(),
            },
            &fixture.async_db,
        )
        .await
        .expect("round 3 submit");
    }
    respond_review_async(
        &fixture.session_id,
        &fixture.task_id,
        &TaskRespondReviewRequest {
            actor: fixture.worker_id.clone(),
            agreed: vec![],
            disputed: vec!["p1".into()],
            note: None,
        },
        &fixture.async_db,
    )
    .await
    .expect("respond round 3");
    let columns = fixture
        .async_db
        .fetch_task_v10_columns(&fixture.session_id, &fixture.task_id)
        .await
        .expect("fetch pre-arbitration")
        .expect("row");
    assert_eq!(
        columns.review_round, 3,
        "three rounds of respond must land review_round at 3"
    );
    assert!(columns.arbitration_json.is_none());
}

// Arbitrate: leader approves -> arbitration_json set, status done.
async fn v10_columns_arbitrate(fixture: &V10ColumnsFixture) {
    arbitrate_review_async(
        &fixture.session_id,
        &fixture.task_id,
        &TaskArbitrateRequest {
            actor: fixture.leader_id.clone(),
            verdict: ReviewVerdict::Approve,
            summary: "shipping".into(),
        },
        &fixture.async_db,
    )
    .await
    .expect("arbitrate");
    let columns = fixture
        .async_db
        .fetch_task_v10_columns(&fixture.session_id, &fixture.task_id)
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
}
