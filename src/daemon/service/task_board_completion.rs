use crate::daemon::db::AsyncDaemonDb;
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::TaskStatus;
use crate::task_board::TaskBoardStatus;

pub(super) async fn validate_linked_task_completion(
    db: &AsyncDaemonDb,
    item_id: &str,
    target_status: Option<TaskBoardStatus>,
) -> Result<(), CliError> {
    if target_status.map(TaskBoardStatus::canonical_persisted_status) != Some(TaskBoardStatus::Done)
    {
        return Ok(());
    }
    let item = db.task_board_item(item_id).await?;
    if item.status == TaskBoardStatus::Done {
        return Ok(());
    }
    let (Some(session_id), Some(work_item_id)) =
        (item.session_id.as_deref(), item.work_item_id.as_deref())
    else {
        if item.session_id.is_none() && item.work_item_id.is_none() {
            return Ok(());
        }
        return Err(completion_error(
            item_id,
            "has an incomplete session/task linkage",
        ));
    };
    let resolved = db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| completion_error(item_id, "links a missing session"))?;
    let task = resolved
        .state
        .tasks
        .get(work_item_id)
        .filter(|task| !task.is_deleted())
        .ok_or_else(|| completion_error(item_id, "links a missing session task"))?;
    match task.status {
        TaskStatus::Done => Ok(()),
        TaskStatus::AwaitingReview | TaskStatus::InReview
            if item.status == TaskBoardStatus::ToReview =>
        {
            Ok(())
        }
        TaskStatus::AwaitingReview | TaskStatus::InReview => Err(completion_error(
            item_id,
            "must first be evaluated into the to_review board state",
        )),
        status => Err(completion_error(
            item_id,
            &format!("links a session task still in {status:?}"),
        )),
    }
}

fn completion_error(item_id: &str, reason: &str) -> CliError {
    CliErrorKind::invalid_transition(format!(
        "task-board item '{item_id}' cannot complete: {reason}"
    ))
    .into()
}

#[cfg(test)]
#[path = "task_board_completion_tests.rs"]
mod tests;
