use sqlx::{Sqlite, Transaction, query_as, query_scalar};

use super::triage_decisions::{TriageDecisionRow, decision_from_row};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::infra::io;
use crate::task_board::{TaskBoardTriageDecisionRecord, is_canonical_decided_at};

pub(crate) const TASK_BOARD_TRIAGE_HISTORY_MAX_LIMIT: u32 = 100;

#[derive(Debug)]
pub(crate) struct TaskBoardTriageHistoryPage {
    pub(crate) decisions: Vec<TaskBoardTriageDecisionRecord>,
    pub(crate) next_before_generation: Option<u64>,
}

#[derive(sqlx::FromRow)]
struct TriageDecisionRecordRow {
    decision_id: String,
    item_id: String,
    generation: i64,
    verdict: String,
    reason_code: String,
    reason_detail: Option<String>,
    evaluator_identity: String,
    evaluator_version: i64,
    evidence_fingerprint: String,
    cause: String,
    decided_at: String,
    is_current: i64,
    superseded_at: Option<String>,
}

impl AsyncDaemonDb {
    pub(crate) async fn task_board_triage_current(
        &self,
        item_id: &str,
    ) -> Result<Option<TaskBoardTriageDecisionRecord>, CliError> {
        io::validate_safe_segment(item_id)?;
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin task board triage read: {error}")))?;
        require_item_in_tx(&mut transaction, item_id).await?;
        let row = query_as::<_, TriageDecisionRecordRow>(
            "SELECT decision_id, item_id, generation, verdict, reason_code, reason_detail,
                    evaluator_identity, evaluator_version, evidence_fingerprint, cause,
                    decided_at, is_current, superseded_at
             FROM task_board_triage_decisions
             WHERE item_id = ?1 AND is_current = 1
             LIMIT 1",
        )
        .bind(item_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| {
            db_error(format!(
                "load current task board triage decision '{item_id}': {error}"
            ))
        })?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board triage read: {error}")))?;
        row.map(record_from_row).transpose()
    }

    pub(crate) async fn task_board_triage_history(
        &self,
        item_id: &str,
        before_generation: Option<u64>,
        limit: u32,
    ) -> Result<TaskBoardTriageHistoryPage, CliError> {
        io::validate_safe_segment(item_id)?;
        let before_generation = before_generation.map(history_generation).transpose()?;
        let limit = history_limit(limit)?;
        let fetch_limit = i64::from(limit) + 1;
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin task board triage history: {error}")))?;
        require_item_in_tx(&mut transaction, item_id).await?;
        let rows = query_as::<_, TriageDecisionRecordRow>(
            "SELECT decision_id, item_id, generation, verdict, reason_code, reason_detail,
                    evaluator_identity, evaluator_version, evidence_fingerprint, cause,
                    decided_at, is_current, superseded_at
             FROM task_board_triage_decisions
             WHERE item_id = ?1 AND (?2 IS NULL OR generation < ?2)
             ORDER BY generation DESC
             LIMIT ?3",
        )
        .bind(item_id)
        .bind(before_generation)
        .bind(fetch_limit)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| {
            db_error(format!(
                "load task board triage history '{item_id}': {error}"
            ))
        })?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board triage history: {error}")))?;
        let limit = usize::try_from(limit)
            .map_err(|_| db_error("task board triage history limit is out of range"))?;
        history_page(rows, limit)
    }
}

async fn require_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<(), CliError> {
    let exists =
        query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM task_board_items WHERE item_id = ?1)")
            .bind(item_id)
            .fetch_one(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("check task board item '{item_id}': {error}")))?;
    if exists {
        Ok(())
    } else {
        Err(db_error(format!("task-board item '{item_id}' not found")))
    }
}

fn history_generation(generation: u64) -> Result<i64, CliError> {
    i64::try_from(generation)
        .ok()
        .filter(|generation| *generation > 0)
        .ok_or_else(|| db_error("task board triage history cursor is out of range"))
}

fn history_limit(limit: u32) -> Result<u32, CliError> {
    (1..=TASK_BOARD_TRIAGE_HISTORY_MAX_LIMIT)
        .contains(&limit)
        .then_some(limit)
        .ok_or_else(|| db_error("task board triage history limit is out of range"))
}

fn history_page(
    rows: Vec<TriageDecisionRecordRow>,
    limit: usize,
) -> Result<TaskBoardTriageHistoryPage, CliError> {
    let has_more = rows.len() > limit;
    let decisions = rows
        .into_iter()
        .take(limit)
        .map(record_from_row)
        .collect::<Result<Vec<_>, _>>()?;
    let next_before_generation = if has_more {
        decisions.last().map(|decision| decision.generation)
    } else {
        None
    };
    Ok(TaskBoardTriageHistoryPage {
        decisions,
        next_before_generation,
    })
}

fn record_from_row(
    row: TriageDecisionRecordRow,
) -> Result<TaskBoardTriageDecisionRecord, CliError> {
    if !is_canonical_decision_id(&row.decision_id) {
        return Err(db_error("stored triage decision id is not canonical"));
    }
    io::validate_safe_segment(&row.item_id)?;
    let generation = u64::try_from(row.generation)
        .ok()
        .filter(|generation| *generation > 0)
        .ok_or_else(|| db_error("stored triage generation is out of range"))?;
    validate_supersession(
        row.is_current,
        &row.decided_at,
        row.superseded_at.as_deref(),
    )?;
    let decision = decision_from_row(TriageDecisionRow {
        verdict: row.verdict,
        reason_code: row.reason_code,
        reason_detail: row.reason_detail,
        evaluator_identity: row.evaluator_identity,
        evaluator_version: row.evaluator_version,
        evidence_fingerprint: row.evidence_fingerprint,
        cause: row.cause,
        decided_at: row.decided_at,
    })?;
    Ok(TaskBoardTriageDecisionRecord::from_decision(
        row.decision_id,
        row.item_id,
        generation,
        decision,
        row.superseded_at,
    ))
}

fn is_canonical_decision_id(value: &str) -> bool {
    value.strip_prefix("triage-").is_some_and(|suffix| {
        suffix.len() == 32
            && suffix
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    })
}

fn validate_supersession(
    is_current: i64,
    decided_at: &str,
    superseded_at: Option<&str>,
) -> Result<(), CliError> {
    let valid = match (is_current, superseded_at) {
        (1, None) => true,
        (0, Some(superseded_at)) => {
            is_canonical_decided_at(superseded_at) && superseded_at >= decided_at
        }
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(db_error(
            "stored triage supersession state is not canonical",
        ))
    }
}

#[cfg(test)]
#[path = "triage_queries_tests.rs"]
mod tests;
