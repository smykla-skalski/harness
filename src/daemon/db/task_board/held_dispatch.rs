use sqlx::{Sqlite, SqliteConnection, Transaction, query, query_as};
use uuid::Uuid;

use super::ITEMS_CHANGE_SCOPE;
use super::admission_lifecycle::{TaskBoardAdmissionCheck, revalidate_dispatch_admission_in_tx};
use super::dispatch_intents::{
    ClaimedTaskBoardDispatch, TaskBoardDispatchClaimAction, decode_applied,
    ensure_dispatch_item_startable,
};
use super::dispatch_workflow_launch::rebind_write_launch;
use super::dispatch_workflow_start::workflow_start_fence;
use super::items::{bump_change_in_tx, load_item_in_tx, replace_item_in_tx};
use crate::daemon::db::policy::{
    consume_approval_grant_in_tx_at, live_approval_grant_in_tx_at, load_workspace_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, CliErrorKind, db_error, utc_now};
use crate::infra::io;
use crate::task_board::policy_graph::PolicyCanvasWorkspace;
use crate::task_board::{
    DispatchAppliedTask, PolicyAction, PolicyDecision, SpawnGateSwitches,
    TaskBoardHeldDispatchItem, TaskBoardHeldDispatchSummary, TaskBoardItem, consumed_grant_id,
    dispatch_policy_from_graph,
};

#[derive(Debug)]
pub(crate) struct HeldTaskBoardDispatch {
    pub(crate) intent_id: String,
    pub(crate) applied: DispatchAppliedTask,
}

impl AsyncDaemonDb {
    pub(crate) async fn held_task_board_dispatch_summary(
        &self,
    ) -> Result<TaskBoardHeldDispatchSummary, CliError> {
        let rows = query_as::<_, (String, String, String, String)>(
            "SELECT intent_id, item_id, session_id, work_item_id
             FROM task_board_dispatch_intents WHERE status = 'held'
             ORDER BY created_at, intent_id",
        )
        .fetch_all(self.pool())
        .await
        .map_err(|error| db_error(format!("list held task board dispatches: {error}")))?;
        let items = rows
            .into_iter()
            .map(
                |(intent_id, board_item_id, session_id, work_item_id)| TaskBoardHeldDispatchItem {
                    intent_id,
                    board_item_id,
                    session_id,
                    work_item_id,
                },
            )
            .collect::<Vec<_>>();
        Ok(TaskBoardHeldDispatchSummary {
            count: items.len(),
            items,
        })
    }

    pub(crate) async fn held_task_board_dispatch(
        &self,
        board_item_id: &str,
    ) -> Result<HeldTaskBoardDispatch, CliError> {
        io::validate_safe_segment(board_item_id)?;
        let row = query_as::<_, (String, String)>(
            "SELECT intent_id, payload_json FROM task_board_dispatch_intents
             WHERE item_id = ?1 AND status = 'held'",
        )
        .bind(board_item_id)
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("load held task board dispatch: {error}")))?
        .ok_or_else(|| held_conflict(board_item_id))?;
        Ok(HeldTaskBoardDispatch {
            intent_id: row.0,
            applied: decode_applied(&row.1)?,
        })
    }

    /// Atomically re-evaluate current spawn policy, consume any one-shot grant,
    /// and claim a held intent immediately before worker startup.
    pub(crate) async fn claim_held_task_board_dispatch(
        &self,
        board_item_id: &str,
    ) -> Result<ClaimedTaskBoardDispatch, CliError> {
        io::validate_safe_segment(board_item_id)?;
        let mut transaction = self
            .begin_immediate_transaction("task board held dispatch delivery")
            .await?;
        let (intent_id, payload_json) =
            load_held_delivery(transaction.as_mut(), board_item_id).await?;
        let mut applied = decode_applied(&payload_json)?;
        let (mut item, revision) = load_item_in_tx(&mut transaction, board_item_id)
            .await?
            .ok_or_else(|| db_error(format!("task-board item '{board_item_id}' not found")))?;
        ensure_held_linkage(&applied, &item)?;
        validate_held_workflow_claim_revision(&applied, revision)?;
        ensure_dispatch_item_startable(
            &item,
            &applied.session_id,
            &applied.work_item_id,
            applied.item.workflow.execution_id.as_deref(),
        )?;
        if let TaskBoardAdmissionCheck::Blocked(admission) =
            revalidate_dispatch_admission_in_tx(&mut transaction, &intent_id, &item, revision)
                .await?
        {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit refused held task board admission: {error}"))
            })?;
            return Err(CliErrorKind::invalid_transition(admission.refusal_message()).into());
        }
        let now = utc_now();
        let authorization =
            authorize_held_delivery(&mut transaction, board_item_id, &item, &now).await?;
        let (decision_id, consumed_approval_grant_id) = match authorization {
            HeldDeliveryAuthorization::Allowed {
                decision_id,
                consumed_approval_grant_id,
            } => (decision_id, consumed_approval_grant_id),
            HeldDeliveryAuthorization::Refused(decision) => {
                transaction.commit().await.map_err(|error| {
                    db_error(format!("commit denied held task board delivery: {error}"))
                })?;
                return Err(CliErrorKind::invalid_transition(format!(
                    "current spawn policy refused held delivery: {decision:?}"
                ))
                .into());
            }
        };
        item.workflow.current_step_id = Some("dispatch".to_string());
        item.workflow.last_error = None;
        if let Some(decision_id) = decision_id {
            item.workflow.push_policy_trace_id(decision_id);
        }
        item.updated_at.clone_from(&now);
        let delivered_item_revision = revision
            .checked_add(1)
            .ok_or_else(|| db_error("task-board item revision is out of range"))?;
        replace_item_in_tx(&mut transaction, &item, delivered_item_revision).await?;
        advance_held_workflow_launch(&mut applied, &item, delivered_item_revision)?;
        applied.item = item;
        let payload = serde_json::to_string(&applied)
            .map_err(|error| db_error(format!("serialize held task board delivery: {error}")))?;
        let claim_token = format!("dispatch-claim-{}", Uuid::new_v4().simple());
        query(
            "UPDATE task_board_dispatch_intents
             SET payload_json = ?3, status = 'starting', attempts = attempts + 1,
                 claim_token = ?2, claimed_at = ?4, updated_at = ?4,
                 consumed_approval_grant_id = ?5
             WHERE intent_id = ?1 AND status = 'held'",
        )
        .bind(&intent_id)
        .bind(&claim_token)
        .bind(payload)
        .bind(&now)
        .bind(consumed_approval_grant_id.as_deref())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("claim held task board dispatch: {error}")))?;
        bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit held task board delivery: {error}")))?;
        Ok(ClaimedTaskBoardDispatch {
            intent_id,
            claim_token,
            applied,
            consumed_approval_grant_id,
            action: TaskBoardDispatchClaimAction::Start,
        })
    }
}

fn advance_held_workflow_launch(
    applied: &mut DispatchAppliedTask,
    item: &TaskBoardItem,
    delivered_item_revision: i64,
) -> Result<(), CliError> {
    if let Some(launch) = applied.read_only_workflow.as_mut() {
        launch.prepared_item_revision = delivered_item_revision;
    }
    if let Some(launch) = applied.write_workflow.as_mut() {
        launch.prepared_item_revision = delivered_item_revision;
        let execution_id = item
            .workflow
            .execution_id
            .as_deref()
            .ok_or_else(|| db_error("held write workflow has no execution id"))?;
        rebind_write_launch(
            item,
            launch,
            execution_id,
            delivered_item_revision
                .checked_add(1)
                .ok_or_else(|| db_error("workflow item revision is out of range"))?,
        )?;
    }
    Ok(())
}

fn validate_held_workflow_claim_revision(
    applied: &DispatchAppliedTask,
    item_revision: i64,
) -> Result<(), CliError> {
    let Some((prepared_item_revision, _)) = workflow_start_fence(applied)? else {
        return Ok(());
    };
    if item_revision != prepared_item_revision {
        return Err(db_error(
            "workflow item revision changed before held worker claim",
        ));
    }
    Ok(())
}

enum HeldDeliveryAuthorization {
    Allowed {
        decision_id: Option<String>,
        consumed_approval_grant_id: Option<String>,
    },
    Refused(PolicyDecision),
}

async fn authorize_held_delivery(
    transaction: &mut Transaction<'_, Sqlite>,
    board_item_id: &str,
    item: &TaskBoardItem,
    now: &str,
) -> Result<HeldDeliveryAuthorization, CliError> {
    let workspace = load_workspace_in_tx(transaction).await?;
    let switches = spawn_gate_switches(workspace.as_ref());
    let live_policy = workspace
        .as_ref()
        .and_then(|workspace| workspace.active_live_canvas())
        .map(|(canvas, graph)| (canvas.id.as_str(), graph));
    let grant = match live_policy {
        Some((_, graph)) => {
            live_approval_grant_in_tx_at(
                transaction.as_mut(),
                board_item_id,
                PolicyAction::SpawnAgent,
                graph.revision,
                now,
            )
            .await?
        }
        None => None,
    };
    let (decision, decision_id) = dispatch_policy_from_graph(
        item,
        live_policy,
        Some(now.to_string()),
        switches,
        grant.as_ref(),
    );
    if !decision.is_allow() {
        return Ok(HeldDeliveryAuthorization::Refused(decision));
    }
    let consumed_approval_grant_id = consumed_grant_id(grant.as_ref(), &decision);
    if let Some(grant_id) = consumed_approval_grant_id.as_deref() {
        let consumed = consume_approval_grant_in_tx_at(transaction.as_mut(), grant_id, now).await?;
        if !consumed {
            return Err(db_error(format!(
                "approval grant expired or was consumed during delivery (grant '{grant_id}')"
            )));
        }
    }
    Ok(HeldDeliveryAuthorization::Allowed {
        decision_id,
        consumed_approval_grant_id,
    })
}

async fn load_held_delivery(
    connection: &mut SqliteConnection,
    board_item_id: &str,
) -> Result<(String, String), CliError> {
    query_as::<_, (String, String)>(
        "SELECT intent_id, payload_json FROM task_board_dispatch_intents
         WHERE item_id = ?1 AND status = 'held'",
    )
    .bind(board_item_id)
    .fetch_optional(connection)
    .await
    .map_err(|error| db_error(format!("load held task board delivery: {error}")))?
    .ok_or_else(|| held_conflict(board_item_id))
}

fn spawn_gate_switches(workspace: Option<&PolicyCanvasWorkspace>) -> SpawnGateSwitches {
    workspace.map_or(
        SpawnGateSwitches {
            requires_live_policy: true,
            kill_switch: false,
        },
        SpawnGateSwitches::from_workspace,
    )
}

fn held_conflict(board_item_id: &str) -> CliError {
    CliErrorKind::session_agent_conflict(format!(
        "task-board dispatch for item '{board_item_id}' is not held"
    ))
    .into()
}

fn ensure_held_linkage(
    applied: &DispatchAppliedTask,
    item: &crate::task_board::TaskBoardItem,
) -> Result<(), CliError> {
    let matches = applied.board_item_id == item.id
        && item.session_id.as_deref() == Some(applied.session_id.as_str())
        && item.work_item_id.as_deref() == Some(applied.work_item_id.as_str())
        && item.workflow.execution_id == applied.item.workflow.execution_id;
    if matches {
        Ok(())
    } else {
        Err(db_error(format!(
            "held task board dispatch '{}' no longer matches its board linkage",
            applied.board_item_id
        )))
    }
}

#[cfg(test)]
#[path = "held_dispatch_tests.rs"]
mod tests;
