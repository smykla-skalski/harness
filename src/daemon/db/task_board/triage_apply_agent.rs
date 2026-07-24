use sqlx::{Sqlite, Transaction, query, query_as};

use super::ITEMS_CHANGE_SCOPE;
use super::dispatch_intents::helpers::has_active_dispatch_reservation_in_tx;
use super::items::{bump_change_in_tx, load_item_with_triage_override_in_tx};
use super::lane_order::{LaneTransitionKind, record_lane_transition_audit_in_tx, replace_with_lane_transition_in_tx};
use super::triage_apply::{apply_placement_effect_in_tx, triage_eligible};
use super::triage_cause::triage_cause;
use super::triage_decisions::{current_triage_decision_in_tx, record_triage_decision_in_tx};
use super::triage_escalation_enqueue::maybe_enqueue_triage_escalation_in_tx;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    AGENT_V1_EVALUATOR_IDENTITY, AGENT_V1_EVALUATOR_VERSION, TaskBoardItem, TaskBoardLaneOrigin,
    TaskBoardTriageEscalationConfig, TaskBoardTriageEscalationRejectReason,
    TaskBoardTriageEscalationVerdictOutcome, TriageReasonCode, TriageVerdict, evidence_fingerprint,
    is_canonical_reason_detail, suppress_placement_for_override,
};

#[derive(sqlx::FromRow)]
struct RunningEscalationRow {
    item_id: String,
    evidence_fingerprint: String,
}

/// Apply one agent-reported triage verdict, inside its own transaction.
/// `escalation_id` and `verdict_token` together authenticate the caller (the
/// escalation worker the daemon itself spawned, via the single-use token
/// minted at claim time) -- this is the only credential the endpoint checks,
/// not the general control-plane session binding, since the reporting
/// process has no daemon session. Every rejection path leaves
/// `task_board_triage_decisions` untouched; only `Accepted` writes a
/// decision, and it does so through the exact same choke-point machinery
/// (`record_triage_decision_in_tx` + `apply_placement_effect_in_tx`) rules
/// and `BuiltInV1` already use, under evaluator identity
/// [`AGENT_V1_EVALUATOR_IDENTITY`].
#[expect(
    clippy::too_many_arguments,
    reason = "one verdict report, named for clarity over a bag struct"
)]
pub(crate) async fn apply_agent_triage_verdict_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    escalation_id: &str,
    verdict_token: &str,
    reported_fingerprint: &str,
    verdict: TriageVerdict,
    rationale: &str,
    decided_at: &str,
    config: &TaskBoardTriageEscalationConfig,
) -> Result<TaskBoardTriageEscalationVerdictOutcome, CliError> {
    let Some(running) = claim_running_escalation_in_tx(transaction, escalation_id, verdict_token).await?
    else {
        return Ok(TaskBoardTriageEscalationVerdictOutcome::Rejected(
            TaskBoardTriageEscalationRejectReason::UnknownRunningEscalation,
        ));
    };
    let (item, revision) = match check_escalation_eligibility_in_tx(
        transaction,
        escalation_id,
        &running.item_id,
        decided_at,
    )
    .await?
    {
        EscalationEligibility::Rejected(outcome) => return Ok(outcome),
        EscalationEligibility::Eligible { item, revision } => (item, revision),
    };
    let fresh_fingerprint = match reject_if_stale_evidence_in_tx(
        transaction,
        escalation_id,
        &item,
        &running.evidence_fingerprint,
        reported_fingerprint,
        config,
        decided_at,
    )
    .await?
    {
        StaleEvidenceCheck::Rejected(outcome) => return Ok(outcome),
        StaleEvidenceCheck::Fresh(fingerprint) => fingerprint,
    };
    record_and_place_agent_verdict_in_tx(
        transaction,
        *item,
        revision,
        verdict,
        rationale,
        &fresh_fingerprint,
        decided_at,
    )
    .await?;
    succeed_running_escalation_in_tx(transaction, escalation_id, decided_at).await?;
    Ok(TaskBoardTriageEscalationVerdictOutcome::Accepted)
}

enum EscalationEligibility {
    Eligible {
        item: Box<TaskBoardItem>,
        revision: i64,
    },
    Rejected(TaskBoardTriageEscalationVerdictOutcome),
}

/// Loads the escalation's item and runs every non-evidence eligibility gate
/// (item still exists, still triage-eligible, no competing dispatch
/// reservation, no override set while the escalation was running). Each
/// failing gate rejects the running row itself before returning, so the
/// caller only has to decide whether to keep going or propagate the
/// rejection outcome.
async fn check_escalation_eligibility_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    escalation_id: &str,
    item_id: &str,
    decided_at: &str,
) -> Result<EscalationEligibility, CliError> {
    let Some((item, revision, existing_override)) =
        load_item_with_triage_override_in_tx(transaction, item_id).await?
    else {
        return reject_running_escalation_in_tx(
            transaction,
            escalation_id,
            decided_at,
            TaskBoardTriageEscalationRejectReason::ItemIneligible,
        )
        .await
        .map(EscalationEligibility::Rejected);
    };
    if !triage_eligible(&item) {
        return reject_running_escalation_in_tx(
            transaction,
            escalation_id,
            decided_at,
            TaskBoardTriageEscalationRejectReason::ItemIneligible,
        )
        .await
        .map(EscalationEligibility::Rejected);
    }
    if has_active_dispatch_reservation_in_tx(transaction, &item.id).await? {
        return reject_running_escalation_in_tx(
            transaction,
            escalation_id,
            decided_at,
            TaskBoardTriageEscalationRejectReason::ReservationHeld,
        )
        .await
        .map(EscalationEligibility::Rejected);
    }
    if suppress_placement_for_override(existing_override.as_ref()) {
        return reject_running_escalation_in_tx(
            transaction,
            escalation_id,
            decided_at,
            TaskBoardTriageEscalationRejectReason::OverrideActive,
        )
        .await
        .map(EscalationEligibility::Rejected);
    }
    Ok(EscalationEligibility::Eligible {
        item: Box::new(item),
        revision,
    })
}

enum StaleEvidenceCheck {
    Fresh(String),
    Rejected(TaskBoardTriageEscalationVerdictOutcome),
}

/// The triple-gate evidence check: the item's fingerprint right now must
/// match both what it was when the escalation was claimed and what the
/// reporting agent itself observed. A mismatch on either side means the
/// item changed underneath the escalation, so the verdict is stale --
/// reject it and re-enqueue for the item's current evidence instead of
/// silently accepting a judgment made on outdated facts.
async fn reject_if_stale_evidence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    escalation_id: &str,
    item: &TaskBoardItem,
    running_fingerprint: &str,
    reported_fingerprint: &str,
    config: &TaskBoardTriageEscalationConfig,
    decided_at: &str,
) -> Result<StaleEvidenceCheck, CliError> {
    let fresh_fingerprint = evidence_fingerprint(item);
    if fresh_fingerprint == running_fingerprint && fresh_fingerprint == reported_fingerprint {
        return Ok(StaleEvidenceCheck::Fresh(fresh_fingerprint));
    }
    reject_running_escalation_in_tx(
        transaction,
        escalation_id,
        decided_at,
        TaskBoardTriageEscalationRejectReason::StaleEvidence,
    )
    .await?;
    if let Some(current) = current_triage_decision_in_tx(transaction, &item.id).await? {
        maybe_enqueue_triage_escalation_in_tx(transaction, &item.id, &current, false, config, decided_at)
            .await?;
    }
    Ok(StaleEvidenceCheck::Rejected(
        TaskBoardTriageEscalationVerdictOutcome::Rejected(
            TaskBoardTriageEscalationRejectReason::StaleEvidence,
        ),
    ))
}

/// Records the decision (through the same choke-point machinery rules and
/// `BuiltInV1` use) and applies its placement effect, persisting the item
/// only if either step actually changed it.
async fn record_and_place_agent_verdict_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: TaskBoardItem,
    revision: i64,
    verdict: TriageVerdict,
    rationale: &str,
    fresh_fingerprint: &str,
    decided_at: &str,
) -> Result<(), CliError> {
    let bounded_rationale = is_canonical_reason_detail(rationale).then_some(rationale);
    let existing = current_triage_decision_in_tx(transaction, &item.id).await?;
    let before = item.clone();
    let mut item = item;
    if let Some(cause) = triage_cause(
        existing.as_ref(),
        fresh_fingerprint,
        AGENT_V1_EVALUATOR_IDENTITY,
        AGENT_V1_EVALUATOR_VERSION,
    ) {
        record_triage_decision_in_tx(
            transaction,
            &item.id,
            verdict,
            TriageReasonCode::AgentVerdict,
            bounded_rationale,
            AGENT_V1_EVALUATOR_IDENTITY,
            AGENT_V1_EVALUATOR_VERSION,
            fresh_fingerprint,
            cause,
            decided_at,
        )
        .await?;
    }
    let manually_placed = item
        .lane_origin
        .as_ref()
        .is_some_and(TaskBoardLaneOrigin::is_manual);
    if !manually_placed {
        apply_placement_effect_in_tx(
            transaction,
            &mut item,
            verdict,
            decided_at,
            AGENT_V1_EVALUATOR_IDENTITY,
        )
        .await?;
    }
    if item != before {
        item.updated_at = decided_at.to_string();
        let write = replace_with_lane_transition_in_tx(
            transaction,
            before,
            revision,
            item,
            LaneTransitionKind::Automatic,
        )
        .await?;
        let items_change_seq = bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
        record_lane_transition_audit_in_tx(transaction, &write, items_change_seq).await?;
    }
    Ok(())
}

/// A CAS claim: only a row that is still `running` under this exact token
/// is returned, and nothing is written yet -- the caller decides the
/// terminal status once every other check has passed.
async fn claim_running_escalation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    escalation_id: &str,
    verdict_token: &str,
) -> Result<Option<RunningEscalationRow>, CliError> {
    query_as::<_, RunningEscalationRow>(
        "SELECT item_id, evidence_fingerprint FROM task_board_triage_escalations
         WHERE escalation_id = ?1 AND status = 'running' AND verdict_token = ?2",
    )
    .bind(escalation_id)
    .bind(verdict_token)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load running task board triage escalation: {error}")))
}

async fn reject_running_escalation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    escalation_id: &str,
    now: &str,
    reason: TaskBoardTriageEscalationRejectReason,
) -> Result<TaskBoardTriageEscalationVerdictOutcome, CliError> {
    query(
        "UPDATE task_board_triage_escalations
         SET status = 'rejected', completed_at = ?2, failure_reason = ?3
         WHERE escalation_id = ?1 AND status = 'running'",
    )
    .bind(escalation_id)
    .bind(now)
    .bind(reject_reason_text(reason))
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("reject task board triage escalation: {error}")))?;
    Ok(TaskBoardTriageEscalationVerdictOutcome::Rejected(reason))
}

async fn succeed_running_escalation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    escalation_id: &str,
    now: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_triage_escalations
         SET status = 'succeeded', completed_at = ?2
         WHERE escalation_id = ?1 AND status = 'running'",
    )
    .bind(escalation_id)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("complete task board triage escalation: {error}")))?;
    Ok(())
}

const fn reject_reason_text(reason: TaskBoardTriageEscalationRejectReason) -> &'static str {
    match reason {
        TaskBoardTriageEscalationRejectReason::UnknownRunningEscalation => {
            "unknown or non-running escalation"
        }
        TaskBoardTriageEscalationRejectReason::ItemIneligible => "item no longer triage-eligible",
        TaskBoardTriageEscalationRejectReason::OverrideActive => {
            "a triage override was set while the escalation was running"
        }
        TaskBoardTriageEscalationRejectReason::ReservationHeld => {
            "a dispatch reservation claimed the item while the escalation was running"
        }
        TaskBoardTriageEscalationRejectReason::StaleEvidence => {
            "item evidence changed while the escalation was running"
        }
    }
}

#[cfg(test)]
#[path = "triage_apply_agent_tests.rs"]
mod tests;
