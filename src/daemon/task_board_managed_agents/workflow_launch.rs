use crate::daemon::http::{DaemonHttpState, require_async_db};
use crate::daemon::protocol::ManagedAgentSnapshot;
use crate::daemon::service::{validate_read_only_workflow_launch, validate_write_workflow_launch};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{DispatchAppliedTask, validate_task_board_read_only_run_context};

use super::requests::codex_worker_request;

pub(super) async fn validate_workflow_launch(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
) -> Result<Option<(i64, u64)>, CliError> {
    validate_read_only_workflow_launch(
        require_async_db(state, "read-only workflow start validation")?,
        applied,
    )
    .await?;
    validate_write_workflow_launch(
        require_async_db(state, "write workflow start validation")?,
        applied,
    )
    .await?;
    launch_revision_fence(applied)
}

pub(super) fn validate_recovered_workflow_worker(
    snapshot: &ManagedAgentSnapshot,
    applied: &DispatchAppliedTask,
) -> Result<(), CliError> {
    let (worktree, task_id) = match (&applied.read_only_workflow, &applied.write_workflow) {
        (Some(_), Some(_)) => return Err(workflow_recovery_conflict(snapshot.agent_id())),
        (Some(launch), None) => {
            if validate_task_board_read_only_run_context(&launch.run_context).is_err()
                || launch.run_context.session_id != applied.session_id
            {
                return Err(workflow_recovery_conflict(snapshot.agent_id()));
            }
            (launch.run_context.worktree.as_str(), None)
        }
        (None, Some(launch)) => {
            if validate_task_board_read_only_run_context(&launch.run_context).is_err()
                || launch.run_context.session_id != applied.session_id
            {
                return Err(workflow_recovery_conflict(snapshot.agent_id()));
            }
            (
                launch.run_context.worktree.as_str(),
                Some(applied.work_item_id.as_str()),
            )
        }
        (None, None) => return Ok(()),
    };
    let ManagedAgentSnapshot::Codex(run) = snapshot else {
        return Err(workflow_recovery_conflict(snapshot.agent_id()));
    };
    let expected = codex_worker_request(applied, &run.run_id);
    let matches = run.project_dir == worktree
        && run.board_item_id.as_deref() == Some(applied.board_item_id.as_str())
        && run.workflow_execution_id == applied.item.workflow.execution_id
        && run.task_id.as_deref() == task_id
        && run.mode == expected.mode
        && run.prompt == expected.prompt
        && run.model == expected.model
        && run.effort == expected.effort;
    if matches {
        Ok(())
    } else {
        Err(workflow_recovery_conflict(&run.run_id))
    }
}

fn workflow_recovery_conflict(worker_id: &str) -> CliError {
    CliErrorKind::session_agent_conflict(format!(
        "managed worker '{worker_id}' contradicts its frozen workflow request"
    ))
    .into()
}

fn launch_revision_fence(applied: &DispatchAppliedTask) -> Result<Option<(i64, u64)>, CliError> {
    match (&applied.read_only_workflow, &applied.write_workflow) {
        (Some(_), Some(_)) => Err(CliErrorKind::invalid_transition(
            "dispatch carries conflicting workflow launches",
        )
        .into()),
        (Some(launch), None) => Ok(Some((
            launch.prepared_item_revision,
            launch.configuration_revision,
        ))),
        (None, Some(launch)) => Ok(Some((
            launch.prepared_item_revision,
            launch.configuration_revision,
        ))),
        (None, None) => Ok(None),
    }
}
