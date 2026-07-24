use std::collections::{BTreeMap, HashSet};

use sqlx::{Sqlite, Transaction, query_as, query_scalar};

use super::mapper::item_from_rows;
use super::rows::{ExternalRefRow, ItemRow};
use super::triage_cause::DecidedEvaluatorFingerprint;
use super::triage_override::triage_override_from_item_row;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{TaskBoardItem, TaskBoardTriageOverride, TriageVerdict};

/// One eligible-domain item plus everything a bulk triage reevaluation needs
/// to reapply its outcome, loaded without a single additional per-item
/// point read.
pub(super) struct TriageBulkEntry {
    pub(super) item: TaskBoardItem,
    pub(super) revision: i64,
    pub(super) override_: Option<TaskBoardTriageOverride>,
    pub(super) current_decision: Option<CurrentDecisionInfo>,
}

/// The current decision's evaluator/evidence identity plus verdict, loaded
/// in the same bulk query as the rest of the item set so a reevaluation pass
/// can compute `triage_cause` per item without a second per-item read.
pub(super) struct CurrentDecisionInfo {
    pub(super) verdict: TriageVerdict,
    pub(super) evaluator_identity: String,
    pub(super) evaluator_version: u32,
    pub(super) evidence_fingerprint: String,
}

impl DecidedEvaluatorFingerprint for CurrentDecisionInfo {
    fn evaluator_identity(&self) -> &str {
        &self.evaluator_identity
    }

    fn evaluator_version(&self) -> u32 {
        self.evaluator_version
    }

    fn evidence_fingerprint(&self) -> &str {
        &self.evidence_fingerprint
    }
}

#[derive(sqlx::FromRow)]
struct CurrentDecisionRow {
    item_id: String,
    verdict: String,
    evaluator_identity: String,
    evaluator_version: i64,
    evidence_fingerprint: String,
}

/// Load every live Backlog/Todo item -- the full domain `triage_eligible`
/// callers further filter (dispatchable kind, unlinked) -- in a fixed number
/// of bulk queries (items, their external refs, and their current decisions)
/// regardless of how many items match. Used by rule-set activation's bulk
/// reevaluation and by preview, neither of which may resolve its item set
/// through N per-item reads.
pub(super) async fn load_triage_bulk_entries_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Vec<TriageBulkEntry>, CliError> {
    let rows = query_as::<_, ItemRow>(
        "SELECT * FROM task_board_items
         WHERE deleted_at IS NULL AND status IN ('backlog', 'todo')",
    )
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load triage bulk item rows: {error}")))?;
    let refs = query_as::<_, ExternalRefRow>(
        "SELECT refs.item_id, refs.position, refs.provider, refs.external_id, refs.url,
                refs.sync_state_json
         FROM task_board_external_refs AS refs
         INNER JOIN task_board_items AS items ON items.item_id = refs.item_id
         WHERE items.deleted_at IS NULL AND items.status IN ('backlog', 'todo')
         ORDER BY refs.item_id, refs.position",
    )
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load triage bulk item refs: {error}")))?;
    let mut refs_by_item = BTreeMap::<String, Vec<ExternalRefRow>>::new();
    for reference in refs {
        refs_by_item
            .entry(reference.item_id.clone())
            .or_default()
            .push(reference);
    }
    let decision_rows = query_as::<_, CurrentDecisionRow>(
        "SELECT decisions.item_id, decisions.verdict, decisions.evaluator_identity,
                decisions.evaluator_version, decisions.evidence_fingerprint
         FROM task_board_triage_decisions AS decisions
         INNER JOIN task_board_items AS items ON items.item_id = decisions.item_id
         WHERE decisions.is_current = 1
           AND items.deleted_at IS NULL AND items.status IN ('backlog', 'todo')",
    )
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load triage bulk current decisions: {error}")))?;
    let mut decision_by_item = BTreeMap::<String, CurrentDecisionInfo>::new();
    for row in decision_rows {
        let evaluator_version = u32::try_from(row.evaluator_version)
            .map_err(|_| db_error("stored triage evaluator version out of range"))?;
        decision_by_item.insert(
            row.item_id,
            CurrentDecisionInfo {
                verdict: parse_verdict(&row.verdict)?,
                evaluator_identity: row.evaluator_identity,
                evaluator_version,
                evidence_fingerprint: row.evidence_fingerprint,
            },
        );
    }
    let mut entries = Vec::with_capacity(rows.len());
    for row in rows {
        let override_ = triage_override_from_item_row(&row)?;
        let current_decision = decision_by_item.remove(&row.item_id);
        let refs = refs_by_item.remove(&row.item_id).unwrap_or_default();
        let (item, revision) = item_from_rows(row, refs)?;
        entries.push(TriageBulkEntry {
            item,
            revision,
            override_,
            current_decision,
        });
    }
    Ok(entries)
}

/// Every item id currently holding an active dispatch reservation, in one
/// fixed query -- the bulk counterpart of
/// `has_active_dispatch_reservation_in_tx`'s per-item point read, so a bulk
/// reevaluation or preview pass over N items never issues N of those reads.
pub(super) async fn load_active_dispatch_reservation_item_ids_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<HashSet<String>, CliError> {
    let item_ids = query_scalar::<_, String>(
        "SELECT DISTINCT item_id FROM task_board_dispatch_intents
         WHERE status IN (
             'preparing', 'preparing_claimed', 'held', 'pending',
             'workflow_prepared', 'starting'
         )",
    )
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load active task board dispatch reservations: {error}")))?;
    Ok(item_ids.into_iter().collect())
}

fn parse_verdict(value: &str) -> Result<TriageVerdict, CliError> {
    match value {
        "todo" => Ok(TriageVerdict::Todo),
        "undecided" => Ok(TriageVerdict::Undecided),
        other => Err(db_error(format!("unknown stored triage verdict '{other}'"))),
    }
}

#[cfg(test)]
#[path = "triage_rules_bulk_load_tests.rs"]
mod tests;
