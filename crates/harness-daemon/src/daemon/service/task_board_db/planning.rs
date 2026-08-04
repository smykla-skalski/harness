use crate::daemon::db::task_board::prelude::*;
use crate::daemon::protocol::{
    TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest,
    TaskBoardPlanSubmitRequest, TaskBoardPlanningResponse,
};
use crate::task_board::planning::PlanningTransition;
use crate::task_board::{TaskBoardItem, approve_plan, begin_planning, revoke_plan, submit_plan};
use crate::workspace::utc_now;
use harness_kernel::errors::CliError;

use super::super::task_board_repository_scope::scoped_task_board_item_db;
use crate::daemon::db_handle::AsyncDaemonDbHandle;

pub(crate) async fn begin_task_board_planning_db(
    db: &AsyncDaemonDbHandle,
    request: &TaskBoardPlanBeginRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    apply_planning_transition_db(db, &request.id, begin_planning).await
}

pub(crate) async fn submit_task_board_plan_db(
    db: &AsyncDaemonDbHandle,
    request: &TaskBoardPlanSubmitRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    apply_planning_transition_db(db, &request.id, |item| submit_plan(item, &request.summary)).await
}

pub(crate) async fn approve_task_board_plan_db(
    db: &AsyncDaemonDbHandle,
    request: &TaskBoardPlanApproveRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    let approved_at = request.approved_at.clone().unwrap_or_else(utc_now);
    apply_planning_transition_db(db, &request.id, |item| {
        approve_plan(item, &request.approved_by, &approved_at)
    })
    .await
}

pub(crate) async fn revoke_task_board_plan_db(
    db: &AsyncDaemonDbHandle,
    request: &TaskBoardPlanRevokeRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    apply_planning_transition_db(db, &request.id, |item| {
        revoke_plan(item, request.actor.as_deref())
    })
    .await
}

async fn apply_planning_transition_db(
    db: &AsyncDaemonDbHandle,
    id: &str,
    transition_for: impl FnOnce(&TaskBoardItem) -> PlanningTransition,
) -> Result<TaskBoardPlanningResponse, CliError> {
    scoped_task_board_item_db(db, id).await?;
    let mut transition = None;
    let mutation = db
        .update_task_board_item(id, |item| {
            let next = transition_for(item);
            item.status = next.to_status;
            item.planning.clone_from(&next.planning);
            transition = Some(next);
            Ok(true)
        })
        .await?
        .expect("task-board planning transition always mutates");
    Ok(TaskBoardPlanningResponse {
        transition: transition.expect("task-board transition was captured"),
        item: mutation.item,
    })
}
