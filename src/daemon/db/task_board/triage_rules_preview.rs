use super::triage_apply::triage_eligible;
use super::triage_rules_bulk_load::{
    load_active_dispatch_reservation_item_ids_in_tx, load_triage_bulk_entries_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{
    TaskBoardTriageEffectiveSource, TriageRuleMatch, TriageRuleSetPreviewDiffEntry,
    TriageRuleSetPreviewResult, TriageRuleSetV1, evaluate_triage_rule_set, validate_triage_rule_set,
};

impl AsyncDaemonDb {
    /// Evaluate `candidate` against one frozen read of the current backlog
    /// without persisting anything, whether or not the candidate is valid --
    /// an author previews in-progress work before ever saving or activating
    /// it. The whole read happens in one transaction that is always rolled
    /// back (never committed), so it is consistent with itself but never
    /// observable as a write to any other reader. Excludes items under an
    /// active dispatch reservation, matching what an actual activation would
    /// skip -- otherwise a preview could promise a change activation never
    /// applies.
    pub(crate) async fn preview_task_board_triage_rules(
        &self,
        candidate: TriageRuleSetV1,
    ) -> Result<TriageRuleSetPreviewResult, CliError> {
        let validation = validate_triage_rule_set(&candidate);
        if !validation.is_valid() {
            return Ok(TriageRuleSetPreviewResult {
                validation,
                diff: Vec::new(),
            });
        }
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin task board triage rules preview: {error}")))?;
        let entries = load_triage_bulk_entries_in_tx(&mut transaction).await?;
        let reserved = load_active_dispatch_reservation_item_ids_in_tx(&mut transaction).await?;
        let diff = entries
            .into_iter()
            .filter(|entry| triage_eligible(&entry.item) && !reserved.contains(&entry.item.id))
            .map(|entry| diff_entry(&candidate, entry))
            .collect();
        Ok(TriageRuleSetPreviewResult { validation, diff })
    }
}

fn diff_entry(
    candidate: &TriageRuleSetV1,
    entry: super::triage_rules_bulk_load::TriageBulkEntry,
) -> TriageRuleSetPreviewDiffEntry {
    let evaluation = evaluate_triage_rule_set(candidate, &entry.item);
    let candidate_matched_rule_id = match evaluation.matched {
        TriageRuleMatch::Rule(id) => Some(id),
        TriageRuleMatch::Default => None,
    };
    let (live_effective_verdict, live_effective_source) = if let Some(override_) = &entry.override_ {
        (Some(override_.verdict), Some(TaskBoardTriageEffectiveSource::Override))
    } else if let Some(decision) = &entry.current_decision {
        (Some(decision.verdict), Some(TaskBoardTriageEffectiveSource::Automatic))
    } else {
        (None, None)
    };
    let governs_placement_change = entry.override_.is_none()
        && live_effective_verdict != Some(evaluation.verdict);
    TriageRuleSetPreviewDiffEntry {
        item_id: entry.item.id,
        live_effective_verdict,
        live_effective_source,
        candidate_verdict: evaluation.verdict,
        candidate_matched_rule_id,
        governs_placement_change,
    }
}

#[cfg(test)]
#[path = "triage_rules_preview_tests.rs"]
mod tests;
