//! The single production implementation of
//! [`super::items::TriageEvaluator`], the interface item mutation declares
//! for what it needs from triage. Kept as one small forwarding file so the
//! day triage moves into its own crate, this file is the entire seam that
//! has to move with it -- every other triage file keeps its own shape, and
//! every item-mutation call site already goes through the trait instead of
//! naming triage's files directly.

use sqlx::{Sqlite, Transaction};

use super::items::{TriageEvaluator, TriageOutcome};
use super::lane_order::{LaneTransitionKind, LaneTransitionWrite};
use super::rows::ItemRow;
use super::{
    triage_apply, triage_apply_rules, triage_audit, triage_escalation_enqueue, triage_override,
};
use crate::daemon::db::CliError;
use crate::task_board::{
    TaskBoardItem, TaskBoardStatus, TaskBoardTriageDecision, TaskBoardTriageEscalationConfig,
    TaskBoardTriageOverride, TriageVerdict,
};

pub(super) struct Triage;

impl TriageEvaluator for Triage {
    async fn apply_active_triage_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item: &mut TaskBoardItem,
        decided_at: &str,
        suppress_placement: bool,
        existing_override: Option<&TaskBoardTriageOverride>,
    ) -> Result<Option<TriageOutcome>, CliError> {
        triage_apply_rules::apply_active_triage_in_tx(
            transaction,
            item,
            decided_at,
            suppress_placement,
            existing_override,
        )
        .await
    }

    async fn reapply_active_override_outcome_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item: &mut TaskBoardItem,
        existing_override: Option<&TaskBoardTriageOverride>,
        decided_at: &str,
    ) -> Result<Option<LaneTransitionKind>, CliError> {
        triage_apply::reapply_active_override_outcome_in_tx(
            transaction,
            item,
            existing_override,
            decided_at,
        )
        .await
    }

    async fn record_triage_decided_audit_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        before: &TaskBoardItem,
        decision: &TaskBoardTriageDecision,
        write: &LaneTransitionWrite,
        items_change_seq: i64,
    ) -> Result<(), CliError> {
        triage_audit::record_triage_decided_audit_in_tx(
            transaction,
            before,
            decision,
            write,
            items_change_seq,
        )
        .await
    }

    async fn record_triage_effect_reapplied_audit_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        before: &TaskBoardItem,
        decision: &TaskBoardTriageDecision,
        write: &LaneTransitionWrite,
        items_change_seq: i64,
    ) -> Result<(), CliError> {
        triage_audit::record_triage_effect_reapplied_audit_in_tx(
            transaction,
            before,
            decision,
            write,
            items_change_seq,
        )
        .await
    }

    async fn maybe_enqueue_triage_escalation_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item_id: &str,
        decision: &TaskBoardTriageDecision,
        override_active: bool,
        config: &TaskBoardTriageEscalationConfig,
        now: &str,
    ) -> Result<(), CliError> {
        triage_escalation_enqueue::maybe_enqueue_triage_escalation_in_tx(
            transaction,
            item_id,
            decision,
            override_active,
            config,
            now,
        )
        .await
    }

    fn triage_override_from_item_row(
        &self,
        row: &ItemRow,
    ) -> Result<Option<TaskBoardTriageOverride>, CliError> {
        triage_override::triage_override_from_item_row(row)
    }

    fn override_implied_status(&self, verdict: TriageVerdict) -> TaskBoardStatus {
        triage_apply::override_implied_status(verdict)
    }
}
