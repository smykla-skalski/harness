use sqlx::{Sqlite, Transaction, query_scalar};

use super::TaskBoardRemoteExecutorStartReceipt;
use crate::daemon::db::{CliError, TaskBoardRemoteAssignmentRecord, db_error};

pub(super) async fn durable_workspace_start_receipt_run_matches(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    receipt: &TaskBoardRemoteExecutorStartReceipt,
    workspace_id: &str,
) -> Result<bool, CliError> {
    let offer = record.require_offer()?;
    let working_copy_id = receipt
        .working_copy_id
        .as_deref()
        .ok_or_else(|| db_error("workspace start receipt has no working copy"))?;
    let runtime_matches = if offer.launch.runtime == "openrouter" {
        query_scalar::<_, bool>(
            "SELECT EXISTS(
               SELECT 1 FROM agent_turn_runs AS runs
               WHERE runs.run_id = ?1 AND runs.session_id = ?2
                 AND runs.workflow_execution_id = ?3 AND runs.project_dir = ?4
                 AND runs.created_at = ?5 AND runs.task_id IS ?6
                 AND runs.board_item_id = ?7 AND runs.requested_runtime = 'openrouter'
                 AND runs.actual_runtime = 'openrouter' AND runs.requested_model IS ?8
             )",
        )
        .bind(&receipt.run_id)
        .bind(workspace_id)
        .bind(&record.execution_id)
        .bind(&receipt.project_dir)
        .bind(&receipt.started_at)
        .bind(&offer.launch.task_id)
        .bind(&offer.launch.board_item_id)
        .bind(&offer.launch.model)
        .fetch_one(transaction.as_mut())
        .await
    } else {
        query_scalar::<_, bool>(
            "SELECT EXISTS(
               SELECT 1 FROM codex_runs AS runs
               WHERE runs.run_id = ?1 AND runs.session_id IS NULL
                 AND runs.workspace_id = ?2 AND runs.workflow_execution_id = ?3
                 AND runs.project_dir = ?4 AND runs.created_at = ?5
                 AND runs.task_id IS ?6 AND runs.board_item_id = ?7
                 AND runs.display_name = ?8
             )",
        )
        .bind(&receipt.run_id)
        .bind(workspace_id)
        .bind(&record.execution_id)
        .bind(&receipt.project_dir)
        .bind(&receipt.started_at)
        .bind(&offer.launch.task_id)
        .bind(&offer.launch.board_item_id)
        .bind(&offer.launch.display_name)
        .fetch_one(transaction.as_mut())
        .await
    }
    .map_err(|error| db_error(format!("verify workspace-owned remote run: {error}")))?;
    if !runtime_matches {
        return Ok(false);
    }
    query_scalar::<_, bool>(
        "SELECT EXISTS(
           SELECT 1 FROM agent_working_copies AS copy
           JOIN agent_workspaces AS workspace ON workspace.workspace_id = copy.workspace_id
           JOIN agent_workspace_members AS member
             ON member.workspace_id = workspace.workspace_id
           WHERE copy.working_copy_id = ?1 AND copy.workspace_id = ?2
             AND copy.worktree_path = ?3 AND copy.status = 'active'
             AND workspace.orchestration_authority = 'workspace'
             AND workspace.selected_legacy_session_id IS NULL
             AND member.managed_agent_id = ?4
             AND member.membership_status = 'joined'
         )",
    )
    .bind(working_copy_id)
    .bind(workspace_id)
    .bind(&receipt.project_dir)
    .bind(&receipt.run_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("verify workspace-owned remote receipt: {error}")))
}
