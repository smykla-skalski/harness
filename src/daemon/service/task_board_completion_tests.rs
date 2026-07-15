use std::path::Path;

use tempfile::tempdir;

use super::*;
use crate::daemon::protocol::{
    SessionJoinRequest, SessionStartRequest, TaskBoardUpdateItemRequest, TaskCreateRequest,
};
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionRole, TaskSeverity};
use crate::task_board::TaskBoardItem;

#[test]
fn linked_item_completion_requires_real_review_state() {
    let dir = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(dir.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_linked_item_completion_gate(dir.path()));
    });
}

async fn assert_linked_item_completion_gate(base: &Path) {
    let project = base.join("project");
    harness_testkit::init_git_repo_with_seed(&project);
    let db = AsyncDaemonDb::connect(&base.join("harness.db"))
        .await
        .expect("connect");
    let session = super::super::start_session_direct_async(
        &SessionStartRequest {
            title: "Completion gate".to_string(),
            context: "Completion gate".to_string(),
            session_id: None,
            project_dir: project.to_string_lossy().into_owned(),
            policy_preset: None,
            base_ref: None,
        },
        &db,
    )
    .await
    .expect("start session");
    super::super::join_session_direct_async(
        &session.session_id,
        &SessionJoinRequest {
            runtime: "codex".to_string(),
            role: SessionRole::Leader,
            fallback_role: None,
            capabilities: Vec::new(),
            name: Some("completion gate leader".to_string()),
            project_dir: project.to_string_lossy().into_owned(),
            persona: None,
        },
        &db,
    )
    .await
    .expect("join leader");
    let task_id = "completion-gate-task";
    super::super::create_task_with_id_async(
        &session.session_id,
        task_id,
        &TaskCreateRequest {
            actor: CONTROL_PLANE_ACTOR_ID.to_string(),
            title: "Completion gate task".to_string(),
            context: None,
            severity: TaskSeverity::Medium,
            suggested_fix: None,
        },
        &db,
    )
    .await
    .expect("create task");
    let mut item = TaskBoardItem::new(
        "completion-gate-item".to_string(),
        "Completion gate item".to_string(),
        "Body".to_string(),
        "2026-07-14T10:00:00Z".to_string(),
    );
    item.status = TaskBoardStatus::InProgress;
    item.session_id = Some(session.session_id.clone());
    item.work_item_id = Some(task_id.to_string());
    db.create_task_board_item(item).await.expect("create item");

    let request = TaskBoardUpdateItemRequest {
        status: Some(TaskBoardStatus::Done),
        ..TaskBoardUpdateItemRequest::default()
    };
    let error = super::super::task_board_db::update_task_board_item_db(
        &db,
        "completion-gate-item",
        &request,
    )
    .await
    .expect_err("in-progress task must block completion");
    assert!(error.message().contains("still in Open"));

    db.update_session_state_immediate(&session.session_id, |state| {
        state.tasks.get_mut(task_id).expect("task").status = TaskStatus::AwaitingReview;
        Ok(())
    })
    .await
    .expect("advance task to review");
    let error = super::super::task_board_db::update_task_board_item_db(
        &db,
        "completion-gate-item",
        &request,
    )
    .await
    .expect_err("board must also reach review state");
    assert!(error.message().contains("to_review"));
    db.update_task_board_item("completion-gate-item", |item| {
        item.status = TaskBoardStatus::ToReview;
        Ok(true)
    })
    .await
    .expect("move board to review");

    let completed = super::super::task_board_db::update_task_board_item_db(
        &db,
        "completion-gate-item",
        &request,
    )
    .await
    .expect("review-ready linked item completes");
    assert_eq!(completed.status, TaskBoardStatus::Done);
}

#[tokio::test]
async fn unlinked_manual_item_can_still_complete() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("connect");
    db.create_task_board_item(TaskBoardItem::new(
        "manual-item".to_string(),
        "Manual item".to_string(),
        String::new(),
        "2026-07-14T10:00:00Z".to_string(),
    ))
    .await
    .expect("create item");
    let completed = super::super::task_board_db::update_task_board_item_db(
        &db,
        "manual-item",
        &TaskBoardUpdateItemRequest {
            status: Some(TaskBoardStatus::Done),
            ..TaskBoardUpdateItemRequest::default()
        },
    )
    .await
    .expect("manual completion");
    assert_eq!(completed.status, TaskBoardStatus::Done);
}
