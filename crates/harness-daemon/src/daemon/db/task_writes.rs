use std::collections::BTreeMap;

use super::{CliError, Connection, WorkItem, db_error};

pub(super) fn replace_tasks(
    transaction: &Connection,
    session_id: &str,
    tasks: &BTreeMap<String, WorkItem>,
) -> Result<(), CliError> {
    transaction
        .execute("DELETE FROM tasks WHERE session_id = ?1", [session_id])
        .map_err(|error| db_error(format!("delete tasks: {error}")))?;

    let mut statement = transaction
        .prepare(
            "INSERT INTO tasks (
                task_id, session_id, title, context, severity, status,
                assigned_to, created_at, updated_at, created_by,
                suggested_fix, source, blocked_reason, completed_at,
                notes_json, checkpoint_summary_json, deleted_at,
                awaiting_review_queued_at, awaiting_review_submitter_agent_id,
                awaiting_review_required_consensus, review_round,
                review_claim_json, consensus_json, arbitration_json, suggested_persona
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16,
                ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25)",
        )
        .map_err(|error| db_error(format!("prepare task insert: {error}")))?;

    for (task_id, task) in tasks {
        let row = super::task_row::TaskRowBindings::from_task(task);
        statement
            .execute(rusqlite::params![
                task_id,
                session_id,
                task.title,
                task.context,
                row.severity,
                row.status,
                task.assigned_to,
                task.created_at,
                task.updated_at,
                task.created_by,
                task.suggested_fix,
                row.source,
                task.blocked_reason,
                task.completed_at,
                row.notes_json,
                row.checkpoint_summary_json,
                task.deleted_at,
                row.awaiting_queued_at,
                row.awaiting_submitter,
                row.awaiting_required_consensus,
                row.review_round,
                row.review_claim_json,
                row.consensus_json,
                row.arbitration_json,
                task.suggested_persona,
            ])
            .map_err(|error| db_error(format!("insert task {task_id}: {error}")))?;
    }
    Ok(())
}
