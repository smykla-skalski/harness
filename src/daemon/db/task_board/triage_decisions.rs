use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};
use uuid::Uuid;

use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardTriageDecision, TriageCause, TriageReasonCode, TriageVerdict, is_canonical_decided_at,
    is_canonical_evaluator_identity, is_canonical_evidence_fingerprint, is_canonical_reason_detail,
};

#[derive(sqlx::FromRow)]
struct TriageDecisionRow {
    verdict: String,
    reason_code: String,
    reason_detail: Option<String>,
    evaluator_identity: String,
    evaluator_version: i64,
    evidence_fingerprint: String,
    cause: String,
    decided_at: String,
}

/// Load the current (`is_current = 1`) `BuiltInV1` decision for one item, if any.
pub(super) async fn current_triage_decision_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<Option<TaskBoardTriageDecision>, CliError> {
    let row = query_as::<_, TriageDecisionRow>(
        "SELECT verdict, reason_code, reason_detail, evaluator_identity, evaluator_version,
                evidence_fingerprint, cause, decided_at
         FROM task_board_triage_decisions WHERE item_id = ?1 AND is_current = 1",
    )
    .bind(item_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "load task board triage decision '{item_id}': {error}"
        ))
    })?;
    row.map(decision_from_row).transpose()
}

/// Supersede the current decision (if any) and append a new current generation.
/// Callers are responsible for deciding whether a new decision is warranted;
/// this always writes one.
#[expect(
    clippy::too_many_arguments,
    reason = "one immutable decision row, named for clarity over a bag struct"
)]
pub(super) async fn record_triage_decision_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    verdict: TriageVerdict,
    reason_code: TriageReasonCode,
    reason_detail: Option<&str>,
    evaluator_identity: &str,
    evaluator_version: u32,
    evidence_fingerprint: &str,
    cause: TriageCause,
    decided_at: &str,
) -> Result<TaskBoardTriageDecision, CliError> {
    if !is_canonical_evaluator_identity(evaluator_identity) {
        return Err(db_error("triage evaluator identity is not canonical"));
    }
    if !is_canonical_evidence_fingerprint(evidence_fingerprint) {
        return Err(db_error("triage evidence fingerprint is not canonical"));
    }
    if reason_detail.is_some_and(|detail| !is_canonical_reason_detail(detail)) {
        return Err(db_error("triage reason detail is not canonical"));
    }
    if !is_canonical_decided_at(decided_at) {
        return Err(db_error("triage decided_at is not canonical"));
    }
    let generation: i64 = query_scalar(
        "SELECT COALESCE(MAX(generation), 0) + 1 FROM task_board_triage_decisions
         WHERE item_id = ?1",
    )
    .bind(item_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "compute triage decision generation '{item_id}': {error}"
        ))
    })?;
    query(
        "UPDATE task_board_triage_decisions SET is_current = 0, superseded_at = ?2
         WHERE item_id = ?1 AND is_current = 1",
    )
    .bind(item_id)
    .bind(decided_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "supersede prior triage decision '{item_id}': {error}"
        ))
    })?;
    let decision_id = format!("triage-{}", Uuid::new_v4().simple());
    query(
        "INSERT INTO task_board_triage_decisions (
             decision_id, item_id, generation, verdict, reason_code, reason_detail,
             evaluator_identity, evaluator_version, evidence_fingerprint, cause, decided_at,
             is_current
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 1)",
    )
    .bind(&decision_id)
    .bind(item_id)
    .bind(generation)
    .bind(verdict_wire(verdict))
    .bind(reason_code_wire(reason_code))
    .bind(reason_detail)
    .bind(evaluator_identity)
    .bind(i64::from(evaluator_version))
    .bind(evidence_fingerprint)
    .bind(cause_wire(cause))
    .bind(decided_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("insert triage decision '{item_id}': {error}")))?;
    Ok(TaskBoardTriageDecision {
        verdict,
        reason_code,
        reason_detail: reason_detail.map(ToOwned::to_owned),
        evaluator_identity: evaluator_identity.to_string(),
        evaluator_version,
        evidence_fingerprint: evidence_fingerprint.to_string(),
        cause,
        decided_at: decided_at.to_string(),
    })
}

/// Re-validates every canonical-shape field on read, not just the wire enums
/// `parse_*` already reject: a `sha256:` prefix and correct length alone (the
/// SQL `CHECK`) do not rule out non-hex characters in the digest, and a row
/// written by anything other than [`record_triage_decision_in_tx`] could
/// otherwise carry a fingerprint, identity, or timestamp the rest of this
/// module never actually produces.
fn decision_from_row(row: TriageDecisionRow) -> Result<TaskBoardTriageDecision, CliError> {
    if !is_canonical_evaluator_identity(&row.evaluator_identity) {
        return Err(db_error("stored triage evaluator identity is not canonical"));
    }
    if !is_canonical_evidence_fingerprint(&row.evidence_fingerprint) {
        return Err(db_error(
            "stored triage evidence fingerprint is not canonical",
        ));
    }
    if row
        .reason_detail
        .as_deref()
        .is_some_and(|detail| !is_canonical_reason_detail(detail))
    {
        return Err(db_error("stored triage reason detail is not canonical"));
    }
    if !is_canonical_decided_at(&row.decided_at) {
        return Err(db_error("stored triage decided_at is not canonical"));
    }
    Ok(TaskBoardTriageDecision {
        verdict: parse_verdict(&row.verdict)?,
        reason_code: parse_reason_code(&row.reason_code)?,
        reason_detail: row.reason_detail,
        evaluator_identity: row.evaluator_identity,
        evaluator_version: u32::try_from(row.evaluator_version)
            .map_err(|_| db_error("stored triage evaluator version out of range"))?,
        evidence_fingerprint: row.evidence_fingerprint,
        cause: parse_cause(&row.cause)?,
        decided_at: row.decided_at,
    })
}

const fn verdict_wire(verdict: TriageVerdict) -> &'static str {
    match verdict {
        TriageVerdict::Todo => "todo",
        TriageVerdict::Undecided => "undecided",
    }
}

fn parse_verdict(value: &str) -> Result<TriageVerdict, CliError> {
    match value {
        "todo" => Ok(TriageVerdict::Todo),
        "undecided" => Ok(TriageVerdict::Undecided),
        other => Err(db_error(format!("unknown stored triage verdict '{other}'"))),
    }
}

const fn reason_code_wire(reason_code: TriageReasonCode) -> &'static str {
    match reason_code {
        TriageReasonCode::NeedsInfoLabel => "needs_info_label",
        TriageReasonCode::NoMeaningfulLabels => "no_meaningful_labels",
        TriageReasonCode::MeaningfulLabel => "meaningful_label",
    }
}

fn parse_reason_code(value: &str) -> Result<TriageReasonCode, CliError> {
    match value {
        "needs_info_label" => Ok(TriageReasonCode::NeedsInfoLabel),
        "no_meaningful_labels" => Ok(TriageReasonCode::NoMeaningfulLabels),
        "meaningful_label" => Ok(TriageReasonCode::MeaningfulLabel),
        other => Err(db_error(format!(
            "unknown stored triage reason code '{other}'"
        ))),
    }
}

const fn cause_wire(cause: TriageCause) -> &'static str {
    match cause {
        TriageCause::Initial => "initial",
        TriageCause::FingerprintChanged => "fingerprint_changed",
        TriageCause::ActiveEvaluatorChanged => "active_evaluator_changed",
    }
}

fn parse_cause(value: &str) -> Result<TriageCause, CliError> {
    match value {
        "initial" => Ok(TriageCause::Initial),
        "fingerprint_changed" => Ok(TriageCause::FingerprintChanged),
        "active_evaluator_changed" => Ok(TriageCause::ActiveEvaluatorChanged),
        other => Err(db_error(format!("unknown stored triage cause '{other}'"))),
    }
}

#[cfg(test)]
#[path = "triage_decisions_tests.rs"]
mod tests;
