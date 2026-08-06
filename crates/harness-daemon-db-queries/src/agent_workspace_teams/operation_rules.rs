use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_protocol::daemon::summaries::{
    AgentWorkspaceMemberOperationKind, AgentWorkspaceMemberOperationOutcome,
};
use sqlx::{Sqlite, Transaction, query, query_scalar};

pub(super) async fn validate_membership_removal(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
    outcome: AgentWorkspaceMemberOperationOutcome,
) -> Result<(), CliError> {
    if outcome == AgentWorkspaceMemberOperationOutcome::Failed {
        return Ok(());
    }
    let selected_leader = query_scalar::<_, i64>(
        "SELECT EXISTS (
             SELECT 1 FROM agent_workspace_teams
             WHERE workspace_id = ?1 AND leader_member_id = ?2
               AND selected_legacy_session_id IS NOT NULL
         )",
    )
    .bind(workspace_id)
    .bind(member_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("validate durable leader removal: {error}")))?;
    if selected_leader == 1 {
        return Err(db_error(
            "cannot remove the durable team leader while a Session owns leadership",
        ));
    }
    Ok(())
}

pub(super) async fn clear_detached_leader(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
    now: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE agent_workspace_teams
         SET leader_member_id = NULL, updated_at = ?3
         WHERE workspace_id = ?1 AND leader_member_id = ?2
           AND selected_legacy_session_id IS NULL",
    )
    .bind(workspace_id)
    .bind(member_id)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("clear removed durable team leader: {error}")))?;
    Ok(())
}

pub(super) async fn apply_successful_operation(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
    kind: AgentWorkspaceMemberOperationKind,
    outcome: AgentWorkspaceMemberOperationOutcome,
    now: &str,
) -> Result<(), CliError> {
    if outcome == AgentWorkspaceMemberOperationOutcome::Failed {
        return Ok(());
    }
    let statement = match kind {
        AgentWorkspaceMemberOperationKind::RuntimeStop => {
            "UPDATE agent_workspace_members
             SET runtime_lifecycle = 'completed',
                 runtime_evidence = 'runtime_stop_succeeded',
                 runtime_override_source_digest = runtime_source_digest,
                 updated_at = ?3
             WHERE workspace_id = ?1 AND member_id = ?2"
        }
        AgentWorkspaceMemberOperationKind::MembershipRemove => {
            "UPDATE agent_workspace_members
             SET membership_status = 'removed', liveness_status = 'removed',
                 membership_override_source_digest = membership_source_digest,
                 updated_at = ?3
             WHERE workspace_id = ?1 AND member_id = ?2"
        }
    };
    query(statement)
        .bind(workspace_id)
        .bind(member_id)
        .bind(now)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("apply durable member operation: {error}")))?;
    if kind == AgentWorkspaceMemberOperationKind::MembershipRemove {
        clear_detached_leader(transaction, workspace_id, member_id, now).await?;
    }
    Ok(())
}
