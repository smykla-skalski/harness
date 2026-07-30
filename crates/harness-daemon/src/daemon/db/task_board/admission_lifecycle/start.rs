use sqlx::{Sqlite, Transaction, query_as, query_scalar};

use super::super::dispatch_admission_queries::DispatchAdmissionQueries;
use super::super::dispatch_admission_tx_ext::TaskBoardDispatchAdmissionTxExt;
use super::super::item_tx_ext::TaskBoardItemTxExt;
use super::TaskBoardAdmissionCheck;
use crate::daemon::db::{AsyncDaemonDb, CliError, CliErrorKind, db_error};
use crate::task_board::{
    AgentMode, TaskBoardItem, TaskBoardLaunchCapability, validate_launch_capability,
};

impl AsyncDaemonDb {
    pub(crate) async fn validate_task_board_dispatch_admission_start(
        &self,
        intent_id: &str,
        claim_token: &str,
        actual_capability: Option<TaskBoardLaunchCapability>,
        expected_read_only_fence: Option<(i64, u64)>,
    ) -> Result<(), CliError> {
        <Self as DispatchAdmissionQueries>::validate_task_board_dispatch_admission_start(
            self,
            intent_id,
            claim_token,
            actual_capability,
            expected_read_only_fence,
        )
        .await
    }
}

/// Real implementation behind
/// [`DispatchAdmissionQueries::validate_task_board_dispatch_admission_start`],
/// called from the single consolidated trait impl in
/// `dispatch_admission_queries.rs` (a trait's methods can only be implemented
/// in one `impl` block per type, so the per-area files hand it a plain
/// function instead of each declaring their own `impl DispatchAdmissionQueries
/// for AsyncDaemonDb`).
pub(in crate::daemon::db::task_board) async fn validate_task_board_dispatch_admission_start(
    db: &AsyncDaemonDb,
    intent_id: &str,
    claim_token: &str,
    actual_capability: Option<TaskBoardLaunchCapability>,
    expected_read_only_fence: Option<(i64, u64)>,
) -> Result<(), CliError> {
    let transaction = db
        .begin_immediate_transaction("task board admission start validation")
        .await?;
    let (transaction, item, expected) = resolve_dispatch_admission_start_in_tx(
        transaction,
        intent_id,
        claim_token,
        expected_read_only_fence,
    )
    .await?;
    if let Some(expected) = expected {
        ensure_launch_capability_matches(item.agent_mode, expected, actual_capability)?;
    }
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board admission validation: {error}")))
}

async fn resolve_dispatch_admission_start_in_tx<'c>(
    mut transaction: Transaction<'c, Sqlite>,
    intent_id: &str,
    claim_token: &str,
    expected_read_only_fence: Option<(i64, u64)>,
) -> Result<
    (
        Transaction<'c, Sqlite>,
        TaskBoardItem,
        Option<TaskBoardLaunchCapability>,
    ),
    CliError,
> {
    let (item_id, item_revision, session_id, work_item_id, execution_id) =
        claimed_item_identity(&mut transaction, intent_id, claim_token).await?;
    let (item, loaded_revision) = transaction
        .load_item_in_tx(&item_id)
        .await?
        .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
    if loaded_revision != item_revision {
        return Err(db_error(
            "task board admission item revision changed while loading",
        ));
    }
    transaction
        .validate_worker_start_fence_in_tx(expected_read_only_fence, loaded_revision)
        .await?;
    super::super::dispatch_intents::ensure_dispatch_item_startable(
        &item,
        &session_id,
        &work_item_id,
        Some(&execution_id),
    )?;
    let admission = transaction
        .revalidate_dispatch_admission_in_tx(intent_id, &item, loaded_revision)
        .await?;
    let expected = match admission {
        TaskBoardAdmissionCheck::Blocked(snapshot) => {
            let error = CliErrorKind::invalid_transition(snapshot.refusal_message()).into();
            transaction.commit().await.map_err(|error| {
                db_error(format!(
                    "commit blocked task board admission validation: {error}"
                ))
            })?;
            return Err(error);
        }
        admission => admission.ensure_allowed()?,
    };
    Ok((transaction, item, expected))
}

fn ensure_launch_capability_matches(
    agent_mode: AgentMode,
    expected: TaskBoardLaunchCapability,
    actual_capability: Option<TaskBoardLaunchCapability>,
) -> Result<(), CliError> {
    let actual_capability = actual_capability.ok_or_else(|| {
        CliError::from(CliErrorKind::invalid_transition(
            "task board admission requires an enforceable launch capability".to_string(),
        ))
    })?;
    validate_launch_capability(agent_mode, actual_capability).map_err(|error| {
        CliError::from(CliErrorKind::invalid_transition(format!(
            "task board launch capability refused: {error}"
        )))
    })?;
    if expected != actual_capability {
        return Err(CliErrorKind::invalid_transition(format!(
            "task board launch capability changed from {expected:?} to {actual_capability:?}"
        ))
        .into());
    }
    Ok(())
}

async fn claimed_item_identity(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    claim_token: &str,
) -> Result<(String, i64, String, String, String), CliError> {
    let (item_id, session_id, work_item_id, execution_id) =
        query_as::<_, (String, String, String, String)>(
            "SELECT item_id, session_id, work_item_id, workflow_execution_id
         FROM task_board_dispatch_intents
         WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'",
        )
        .bind(intent_id)
        .bind(claim_token)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load claimed task board admission intent: {error}")))?
        .ok_or_else(|| {
            db_error(format!(
                "task board dispatch intent '{intent_id}' is not claimed"
            ))
        })?;
    let item_revision =
        query_scalar::<_, i64>("SELECT revision FROM task_board_items WHERE item_id = ?1")
            .bind(&item_id)
            .fetch_one(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("load claimed task board item revision: {error}")))?;
    Ok((
        item_id,
        item_revision,
        session_id,
        work_item_id,
        execution_id,
    ))
}
