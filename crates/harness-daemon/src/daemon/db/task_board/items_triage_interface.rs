//! Item mutation's own declared boundary onto triage evaluation: exactly
//! what `items.rs`/`items_create.rs`/`items_update.rs` need triage to do
//! inside an ingress transaction, and nothing else. Item mutation depends
//! only on [`TriageEvaluator`], never on any of triage's own files by name,
//! so triage can move into its own crate later without item mutation moving
//! with it -- the same technique #1074 used to free the provider-sync
//! queries from `AsyncDaemonDb`'s inherent impls, applied here to a peer
//! module boundary instead of a shared connection type.
//! [`super::super::triage_interface::Triage`], defined next to triage's own
//! code, is the only production implementation.
//!
//! The reverse direction -- triage's own entry points
//! (`triage_apply_agent.rs`'s agent-verdict endpoint,
//! `triage_override/mutations.rs`'s override set/clear,
//! `triage_rules_reevaluation.rs`'s bulk rule-set-activation pass) calling
//! `bump_change_in_tx`, `load_item_with_triage_override_in_tx`, and
//! `apply_task_board_item_status_transition_in_tx` -- does not need this
//! same inversion: item mutation is the lower layer every task-board area,
//! triage included, already depends on directly, so triage keeps importing
//! those three from `items` by name instead of through a trait.

use sqlx::{Sqlite, Transaction};

use super::super::lane_order::{LaneTransitionKind, LaneTransitionWrite};
use super::super::rows::ItemRow;
use crate::daemon::db::CliError;
use crate::task_board::{
    TaskBoardItem, TaskBoardStatus, TaskBoardTriageDecision, TaskBoardTriageEscalationConfig,
    TaskBoardTriageOverride, TriageVerdict,
};

/// Distinguishes a freshly recorded decision (a new history generation) from
/// an existing decision whose placement effect was merely reapplied (no new
/// generation) -- item mutation's audit dispatch must never report the
/// latter as a fresh decision. Owned here instead of by triage so item
/// mutation can match on its variants without depending on triage's module.
#[derive(Debug)]
pub(in super::super) enum TriageOutcome {
    Decided(TaskBoardTriageDecision),
    RetainedEffect(TaskBoardTriageDecision),
}

impl TriageOutcome {
    pub(in super::super) const fn decision(&self) -> &TaskBoardTriageDecision {
        match self {
            Self::Decided(decision) | Self::RetainedEffect(decision) => decision,
        }
    }
}

/// What item mutation needs triage to do inside its own ingress transaction:
/// evaluate and place (`apply_active_triage_in_tx`), reassert an active
/// override's rank (`reapply_active_override_outcome_in_tx`), audit whatever
/// that produced, escalate an undecided verdict, decode an override already
/// sitting on a row item mutation just fetched, and translate a verdict into
/// the lane it implies (`override_implied_status`), for item mutation's own
/// conflicting-write rejection check. Every method mirrors an existing
/// triage function one-to-one -- the production implementation is a plain
/// forward, not new logic.
pub(in super::super) trait TriageEvaluator {
    async fn apply_active_triage_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item: &mut TaskBoardItem,
        decided_at: &str,
        suppress_placement: bool,
        existing_override: Option<&TaskBoardTriageOverride>,
    ) -> Result<Option<TriageOutcome>, CliError>;

    async fn reapply_active_override_outcome_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item: &mut TaskBoardItem,
        existing_override: Option<&TaskBoardTriageOverride>,
        decided_at: &str,
    ) -> Result<Option<LaneTransitionKind>, CliError>;

    async fn record_triage_decided_audit_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        before: &TaskBoardItem,
        decision: &TaskBoardTriageDecision,
        write: &LaneTransitionWrite,
        items_change_seq: i64,
    ) -> Result<(), CliError>;

    async fn record_triage_effect_reapplied_audit_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        before: &TaskBoardItem,
        decision: &TaskBoardTriageDecision,
        write: &LaneTransitionWrite,
        items_change_seq: i64,
    ) -> Result<(), CliError>;

    async fn maybe_enqueue_triage_escalation_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item_id: &str,
        decision: &TaskBoardTriageDecision,
        override_active: bool,
        config: &TaskBoardTriageEscalationConfig,
        now: &str,
    ) -> Result<(), CliError>;

    fn triage_override_from_item_row(
        &self,
        row: &ItemRow,
    ) -> Result<Option<TaskBoardTriageOverride>, CliError>;

    fn override_implied_status(&self, verdict: TriageVerdict) -> TaskBoardStatus;
}
