use std::path::Path;

use crate::daemon::protocol::{
    TaskAssignRequest, TaskClaimReviewRequest, TaskCreateRequest, TaskSubmitForReviewRequest,
    TaskSubmitReviewRequest, TaskUpdateRequest,
};
use crate::session::types::{ReviewVerdict, SessionRole, TaskStatus};

use super::*;
use crate::daemon::db::AsyncSessionSummaryQueries;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::db_open::AsyncDaemonDbConnect;

#[test]
fn submit_review_async_concurrent_reviewers_close_quorum_without_lost_state() {
    with_temp_project(|project| {
        let runtime_tokio = tokio::runtime::Runtime::new().expect("runtime");
        runtime_tokio.block_on(async {
            let fixture = review_quorum_setup(project).await;
            review_quorum_concurrent_approve_and_assert(&fixture).await;
        });
    });
}

struct ReviewQuorumFixture {
    async_db: AsyncDaemonDbHandle,
    session_id: String,
    task_id: String,
    reviewer_gemini: String,
    reviewer_claude: String,
}

// Joins one agent under an isolated runtime session id and returns its
// agent_id; `role`/`runtime` double as the lookup key since each runtime
// only ever joins once per fixture.
async fn review_quorum_join_agent(
    async_db: &AsyncDaemonDbHandle,
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

// Session plus its three joined agents, before any task exists yet.
struct ReviewQuorumSession {
    async_db: AsyncDaemonDbHandle,
    session_id: String,
    leader_id: String,
    worker_id: String,
    reviewer_gemini: String,
    reviewer_claude: String,
}

async fn review_quorum_start_session(project: &Path) -> ReviewQuorumSession {
    let db_path = project
        .parent()
        .expect("project parent")
        .join("daemon.sqlite");
    let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");
    let async_db = AsyncDaemonDbHandle(async_db);

    let state = start_direct_session_async(
        &async_db,
        project,
        "1b2673b9-af39-5493-a17b-ef8c2bbe86d9",
        "async submit_review quorum",
        "async review flow",
        None,
    )
    .await;
    let leader_id = state.leader_id.clone().expect("leader id");
    let worker_id = review_quorum_join_agent(
        &async_db,
        project,
        &state.session_id,
        "CODEX_SESSION_ID",
        "async-review-worker",
        "codex",
        SessionRole::Worker,
    )
    .await;
    let reviewer_gemini = review_quorum_join_agent(
        &async_db,
        project,
        &state.session_id,
        "GEMINI_SESSION_ID",
        "async-review-gemini",
        "gemini",
        SessionRole::Reviewer,
    )
    .await;
    let reviewer_claude = review_quorum_join_agent(
        &async_db,
        project,
        &state.session_id,
        "CLAUDE_SESSION_ID",
        "async-review-claude",
        "claude",
        SessionRole::Reviewer,
    )
    .await;

    ReviewQuorumSession {
        async_db,
        session_id: state.session_id,
        leader_id,
        worker_id,
        reviewer_gemini,
        reviewer_claude,
    }
}

async fn review_quorum_setup(project: &Path) -> ReviewQuorumFixture {
    let session = review_quorum_start_session(project).await;

    let created = create_task_async(
        &session.session_id,
        &TaskCreateRequest {
            actor: session.leader_id.clone(),
            title: "review flow task".into(),
            context: None,
            severity: crate::session::types::TaskSeverity::Medium,
            suggested_fix: None,
        },
        &session.async_db,
    )
    .await
    .expect("create task");
    let task_id = created.tasks[0].task_id.clone();

    assign_task_async(
        &session.session_id,
        &task_id,
        &TaskAssignRequest {
            actor: session.leader_id,
            agent_id: session.worker_id.clone(),
        },
        &session.async_db,
        crate::daemon::service::WakeDispatch::none(),
    )
    .await
    .expect("assign task");
    update_task_async(
        &session.session_id,
        &task_id,
        &TaskUpdateRequest {
            actor: session.worker_id.clone(),
            status: TaskStatus::InProgress,
            note: None,
        },
        &session.async_db,
        crate::daemon::service::WakeDispatch::none(),
    )
    .await
    .expect("move task in_progress");
    submit_for_review_async(
        &session.session_id,
        &task_id,
        &TaskSubmitForReviewRequest {
            actor: session.worker_id,
            summary: None,
            suggested_persona: None,
        },
        &session.async_db,
    )
    .await
    .expect("submit_for_review async");
    claim_review_async(
        &session.session_id,
        &task_id,
        &TaskClaimReviewRequest {
            actor: session.reviewer_gemini.clone(),
        },
        &session.async_db,
    )
    .await
    .expect("gemini claim");
    claim_review_async(
        &session.session_id,
        &task_id,
        &TaskClaimReviewRequest {
            actor: session.reviewer_claude.clone(),
        },
        &session.async_db,
    )
    .await
    .expect("claude claim");

    ReviewQuorumFixture {
        async_db: session.async_db,
        session_id: session.session_id,
        task_id,
        reviewer_gemini: session.reviewer_gemini,
        reviewer_claude: session.reviewer_claude,
    }
}

async fn review_quorum_concurrent_approve_and_assert(fixture: &ReviewQuorumFixture) {
    let gemini_request = TaskSubmitReviewRequest {
        actor: fixture.reviewer_gemini.clone(),
        verdict: ReviewVerdict::Approve,
        summary: "approve from gemini".into(),
        points: Vec::new(),
    };
    let claude_request = TaskSubmitReviewRequest {
        actor: fixture.reviewer_claude.clone(),
        verdict: ReviewVerdict::Approve,
        summary: "approve from claude".into(),
        points: Vec::new(),
    };
    let (gemini, claude) = tokio::join!(
        submit_review_async(
            &fixture.session_id,
            &fixture.task_id,
            &gemini_request,
            &fixture.async_db
        ),
        submit_review_async(
            &fixture.session_id,
            &fixture.task_id,
            &claude_request,
            &fixture.async_db
        )
    );
    gemini.expect("gemini submit");
    claude.expect("claude submit");

    let resolved_after = fixture
        .async_db
        .resolve_session(&fixture.session_id)
        .await
        .expect("resolve")
        .expect("present");
    let task = resolved_after
        .state
        .tasks
        .get(&fixture.task_id)
        .expect("task");
    assert_eq!(task.status, TaskStatus::Done);
    let consensus = task.consensus.as_ref().expect("consensus");
    assert_eq!(consensus.verdict, ReviewVerdict::Approve);
    assert_eq!(consensus.reviewer_agent_ids.len(), 2);
}
