use std::path::Path;

use super::{ExecutorFixture, INSTANCE, NOW};
use crate::daemon::db::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorStartAuthority,
    TaskBoardRemoteExecutorStartIoPermit, TaskBoardRemoteMutationOutcome,
};
use crate::daemon::protocol::{CodexRunSnapshot, CodexRunStatus};

pub(crate) async fn authorize_and_start_executor(
    fixture: &ExecutorFixture,
    assignment_id: &str,
    started_at: &str,
) -> TaskBoardRemoteMutationOutcome {
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(assignment_id, INSTANCE, started_at)
        .await
        .expect("claim executor start authority")
        .expect("executor start remains authorized");
    let assignment = fixture
        .db
        .task_board_remote_assignment(assignment_id)
        .await
        .expect("load authorized executor assignment")
        .expect("authorized executor assignment");
    let (project_dir, permit) =
        persist_executor_run(fixture, &assignment, &authority, started_at).await;
    fixture
        .db
        .adopt_task_board_remote_executor_start(&permit, Path::new(&project_dir), started_at)
        .await
        .expect("adopt durable executor start")
}

pub(crate) async fn persist_executor_run(
    fixture: &ExecutorFixture,
    assignment: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    started_at: &str,
) -> (String, TaskBoardRemoteExecutorStartIoPermit) {
    let project_dir = format!("/tmp/{}", authority.identity.workspace_ref);
    seed_executor_session(
        fixture,
        assignment,
        &authority.identity.session_id,
        &project_dir,
    )
    .await;
    let permit = fixture
        .db
        .claim_task_board_remote_executor_start_io_permit(
            authority,
            Path::new(&project_dir),
            started_at,
        )
        .await
        .expect("claim executor Start I/O permit")
        .expect_acquired("executor Start I/O remains permitted");
    save_executor_codex_run(fixture, assignment, authority, &project_dir, started_at).await;
    (project_dir, permit)
}

/// Seeds the deterministic session and saves the deterministic Codex run WITHOUT
/// acquiring a Start I/O permit, reproducing the pre-permit exact-run race: a
/// durable run whose permit transaction rolled back after the run side-effect,
/// leaving the assignment Claimed with a start authority but no permit.
pub(crate) async fn persist_pre_permit_executor_run(
    fixture: &ExecutorFixture,
    assignment: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    started_at: &str,
) -> String {
    let project_dir = format!("/tmp/{}", authority.identity.workspace_ref);
    seed_executor_session(
        fixture,
        assignment,
        &authority.identity.session_id,
        &project_dir,
    )
    .await;
    save_executor_codex_run(fixture, assignment, authority, &project_dir, started_at).await;
    project_dir
}

async fn save_executor_codex_run(
    fixture: &ExecutorFixture,
    assignment: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    project_dir: &str,
    started_at: &str,
) {
    let offer = assignment.require_offer().expect("strict executor offer");
    let request = offer.launch.codex_request();
    fixture
        .db
        .save_codex_run(&CodexRunSnapshot {
            run_id: authority.identity.run_id.clone(),
            session_id: authority.identity.session_id.clone(),
            task_id: request.task_id,
            board_item_id: request.board_item_id,
            workflow_execution_id: request.workflow_execution_id,
            session_agent_id: None,
            display_name: request.name,
            project_dir: project_dir.to_owned(),
            thread_id: request.resume_thread_id,
            turn_id: None,
            mode: request.mode,
            status: CodexRunStatus::Running,
            prompt: request.prompt,
            latest_summary: None,
            final_message: None,
            error: None,
            pending_approvals: Vec::new(),
            resolved_approvals: Vec::new(),
            events: Vec::new(),
            created_at: started_at.into(),
            updated_at: started_at.into(),
            model: request.model,
            effort: request.effort,
        })
        .await
        .expect("persist durable executor Codex run");
}

async fn seed_executor_session(
    fixture: &ExecutorFixture,
    assignment: &TaskBoardRemoteAssignmentRecord,
    session_id: &str,
    project_dir: &str,
) {
    sqlx::query(
        "INSERT OR IGNORE INTO projects (
             project_id, name, project_dir, repository_root, checkout_id,
             checkout_name, context_root, is_worktree, discovered_at, updated_at
         ) VALUES ('remote-executor-project', 'remote-executor', ?1, ?1,
                   'remote-executor-checkout', 'remote-executor', ?1, 1, ?2, ?2)",
    )
    .bind(project_dir)
    .bind(NOW)
    .execute(fixture.db.pool())
    .await
    .expect("seed remote executor project");
    sqlx::query(
        "INSERT OR IGNORE INTO sessions (
             session_id, project_id, schema_version, title, context, status,
             created_at, updated_at, metrics_json, state_json, is_active
         ) VALUES (?1, 'remote-executor-project', 1, ?4,
                   ?5, 'active', ?2, ?2, '{}', ?3, 1)",
    )
    .bind(session_id)
    .bind(NOW)
    .bind(
        serde_json::json!({
            "session_id": session_id,
            "worktree_path": project_dir,
            "origin_path": assignment.executor_checkout_path.as_deref(),
            "branch_ref": format!("harness/{session_id}"),
        })
        .to_string(),
    )
    .bind(format!("Remote Task Board {}", assignment.execution_id))
    .bind(format!(
        "Remote Task Board assignment {} fencing epoch {}",
        assignment.assignment_id, assignment.fencing_epoch
    ))
    .execute(fixture.db.pool())
    .await
    .expect("seed remote executor session");
}
