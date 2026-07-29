use sqlx::{Sqlite, Transaction, query, query_scalar};
use uuid::Uuid;

use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    AGENT_V1_EVALUATOR_IDENTITY, TaskBoardTriageDecision, TaskBoardTriageEscalationConfig,
    TriageVerdict,
};

#[derive(sqlx::FromRow)]
struct ActiveEscalationRow {
    escalation_id: String,
    evidence_fingerprint: String,
    status: String,
}

/// Enqueue (or supersede-and-re-enqueue, or no-op) a triage escalation for
/// `item_id`'s freshly recorded `decision`, inside the caller's ingress
/// transaction. Called from every ingress path that can produce a fresh
/// `Undecided` decision: `items.rs::record_triage_or_lane_audit_in_tx`
/// (covers both item create and item update), `provider_exclusion.rs`'s
/// restore path, and `triage_override.rs`'s override-clear path.
///
/// Deliberately NOT called from rule-set activation's bulk reevaluation
/// (`triage_rules_reevaluation.rs`): that pass administratively re-evaluates
/// already-triaged items when the *active evaluator itself* changes, not
/// because new evidence arrived on any one item. Escalating every
/// still-Undecided item on every activation would let one administrative
/// action exhaust the queue-depth bound below in one shot -- exactly the
/// "large sync spawns unlimited agents" failure mode this bound exists to
/// prevent, just triggered by activation instead of a sync. An item that
/// stays genuinely Undecided after a reevaluation still escalates on its
/// next real evidence change through one of the four call sites above.
pub(super) async fn maybe_enqueue_triage_escalation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    decision: &TaskBoardTriageDecision,
    override_active: bool,
    config: &TaskBoardTriageEscalationConfig,
    now: &str,
) -> Result<(), CliError> {
    if !escalation_applies(decision, override_active, config) {
        return Ok(());
    }
    match load_active_escalation_in_tx(transaction, item_id).await? {
        Some(active) if active.evidence_fingerprint == decision.evidence_fingerprint => Ok(()),
        Some(active) if active.status == "pending" => {
            supersede_and_enqueue_in_tx(
                transaction,
                &active.escalation_id,
                item_id,
                decision,
                config,
                now,
            )
            .await
        }
        // A `running` escalation is left alone here -- it is already claimed
        // by the executor and cannot be superseded (see the migration's
        // lifecycle CHECK: `superseded` requires a never-started row). If it
        // reports back with a now-stale fingerprint, the verdict handler
        // re-enqueues for the item's then-current fingerprint (see
        // `triage_apply_agent.rs`'s `StaleEvidence` path). A timeout does
        // NOT re-enqueue -- no-retry is deliberate (see the config's own
        // docs) -- so a timed-out item stays without an active escalation
        // until its next genuine evidence change.
        Some(_) => Ok(()),
        None => insert_pending_escalation_in_tx(transaction, item_id, decision, config, now).await,
    }
}

/// An agent-reported verdict is already the escalation's own output, so
/// re-escalating it would loop; an overridden item has an operator decision
/// that outranks the queue entirely.
fn escalation_applies(
    decision: &TaskBoardTriageDecision,
    override_active: bool,
    config: &TaskBoardTriageEscalationConfig,
) -> bool {
    config.enabled
        && decision.verdict == TriageVerdict::Undecided
        && decision.evaluator_identity != AGENT_V1_EVALUATOR_IDENTITY
        && !override_active
}

async fn supersede_and_enqueue_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    superseded_escalation_id: &str,
    item_id: &str,
    decision: &TaskBoardTriageDecision,
    config: &TaskBoardTriageEscalationConfig,
    now: &str,
) -> Result<(), CliError> {
    supersede_pending_escalation_in_tx(transaction, superseded_escalation_id, now).await?;
    insert_pending_escalation_in_tx(transaction, item_id, decision, config, now).await
}

async fn load_active_escalation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<Option<ActiveEscalationRow>, CliError> {
    sqlx::query_as::<_, ActiveEscalationRow>(
        "SELECT escalation_id, evidence_fingerprint, status
         FROM task_board_triage_escalations
         WHERE item_id = ?1 AND status IN ('pending', 'running')",
    )
    .bind(item_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load active task board triage escalation: {error}")))
}

async fn supersede_pending_escalation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    escalation_id: &str,
    now: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_triage_escalations
         SET status = 'superseded', completed_at = ?2
         WHERE escalation_id = ?1 AND status = 'pending'",
    )
    .bind(escalation_id)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("supersede task board triage escalation: {error}")))?;
    Ok(())
}

async fn insert_pending_escalation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    decision: &TaskBoardTriageDecision,
    config: &TaskBoardTriageEscalationConfig,
    now: &str,
) -> Result<(), CliError> {
    let active_count: i64 = query_scalar(
        "SELECT COUNT(*) FROM task_board_triage_escalations WHERE status IN ('pending', 'running')",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "count active task board triage escalations: {error}"
        ))
    })?;
    if active_count >= i64::try_from(config.max_pending).unwrap_or(i64::MAX) {
        return Ok(());
    }
    let escalation_id = format!("triage-escalation-{}", Uuid::new_v4());
    query(
        "INSERT INTO task_board_triage_escalations (
             escalation_id, item_id, evidence_fingerprint, status, attempt, requested_at
         ) VALUES (?1, ?2, ?3, 'pending', 1, ?4)",
    )
    .bind(&escalation_id)
    .bind(item_id)
    .bind(&decision.evidence_fingerprint)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("insert task board triage escalation: {error}")))?;
    Ok(())
}

#[cfg(test)]
#[path = "triage_escalation_enqueue_tests.rs"]
mod tests;
