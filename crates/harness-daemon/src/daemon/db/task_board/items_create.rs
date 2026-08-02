use sqlx::{Sqlite, Transaction};

use super::super::ITEMS_CHANGE_SCOPE;
use super::super::item_tx_ext::TaskBoardItemTxExt;
use super::super::lane_order::{
    LaneTransitionKind, LaneTransitionWrite, insert_with_lane_transition_in_tx,
    replace_with_lane_transition_in_tx,
};
use super::super::projects::resolve_item_project_in_tx;
use super::super::item_core_queries::ItemCoreQueries;
use super::super::triage_interface::Triage;
use super::{
    TaskBoardMutation, TaskBoardMutationKind, TaskBoardTriageIngress, TriageEvaluator,
    TriageOutcome, bump_change_in_tx, record_triage_or_lane_audit_in_tx, validate_item,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::TaskBoardItem;

impl AsyncDaemonDb {
    /// Insert one new Task Board item. Never evaluates `BuiltInV1`: every
    /// internal lane/dispatch/workflow/migration/test-fixture constructor
    /// must keep using this method so an unrelated internal create can never
    /// become accidental triage ingress. The public create API and provider
    /// import use the `_with_triage` methods below instead.
    ///
    /// # Errors
    /// Returns [`CliError`] when the item is invalid or the insert fails.
    pub async fn create_task_board_item(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        <Self as ItemCoreQueries>::create_task_board_item(self, item).await
    }

    /// Like [`create_task_board_item`], but also evaluates `BuiltInV1` in the
    /// same transaction, for the public create API.
    pub(crate) async fn create_task_board_item_with_triage(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        <Self as ItemCoreQueries>::create_task_board_item_with_triage(self, item).await
    }

    /// Like [`create_task_board_item_with_triage`], but for a create whose
    /// request named the starting lane. See
    /// [`ItemCoreQueries::create_task_board_item_at_requested_status`] for
    /// the full contract.
    pub(crate) async fn create_task_board_item_at_requested_status(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        <Self as ItemCoreQueries>::create_task_board_item_at_requested_status(self, item).await
    }

    /// Like [`create_task_board_item`], but also evaluates `BuiltInV1` in the
    /// same transaction, for provider import.
    pub(crate) async fn create_task_board_item_with_provider_triage(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        <Self as ItemCoreQueries>::create_task_board_item_with_provider_triage(self, item).await
    }
}

pub(crate) async fn create_task_board_item(
    db: &AsyncDaemonDb,
    item: TaskBoardItem,
) -> Result<TaskBoardMutation, CliError> {
    create_task_board_item_impl(db, item, TaskBoardTriageIngress::None, false).await
}

pub(crate) async fn create_task_board_item_with_triage(
    db: &AsyncDaemonDb,
    item: TaskBoardItem,
) -> Result<TaskBoardMutation, CliError> {
    create_task_board_item_impl(db, item, TaskBoardTriageIngress::HumanUpdate, false).await
}

pub(crate) async fn create_task_board_item_at_requested_status(
    db: &AsyncDaemonDb,
    item: TaskBoardItem,
) -> Result<TaskBoardMutation, CliError> {
    create_task_board_item_impl(db, item, TaskBoardTriageIngress::HumanUpdate, true).await
}

pub(crate) async fn create_task_board_item_with_provider_triage(
    db: &AsyncDaemonDb,
    item: TaskBoardItem,
) -> Result<TaskBoardMutation, CliError> {
    create_task_board_item_impl(db, item, TaskBoardTriageIngress::ProviderReconcile, false).await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "sequential create/insert/triage/audit/commit steps, each already its own helper"
)]
async fn create_task_board_item_impl(
    db: &AsyncDaemonDb,
    mut item: TaskBoardItem,
    ingress: TaskBoardTriageIngress,
    suppress_placement: bool,
) -> Result<TaskBoardMutation, CliError> {
    validate_item(&item)?;
    item.status = item.status.canonical_persisted_status();
    validate_item(&item)?;
    let mut transaction = db
        .begin_immediate_transaction("task board item create")
        .await?;
    reject_if_item_exists_in_tx(&mut transaction, &item.id).await?;
    resolve_item_project_in_tx(&mut transaction, &mut item).await?;
    let inserted = insert_with_lane_transition_in_tx(&mut transaction, item).await?;
    let before_triage = inserted.item.clone();
    let (write, outcome) = match ingress {
        TaskBoardTriageIngress::None => (inserted, None),
        TaskBoardTriageIngress::HumanUpdate | TaskBoardTriageIngress::ProviderReconcile => {
            apply_triage_after_insert_in_tx(&mut transaction, inserted, suppress_placement).await?
        }
    };
    let change_revision = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
    let mutation_kind =
        (ingress != TaskBoardTriageIngress::None).then_some(TaskBoardMutationKind::Create);
    record_triage_or_lane_audit_in_tx(
        &mut transaction,
        &before_triage,
        outcome.as_ref(),
        mutation_kind,
        &write,
        change_revision,
        false,
        &db.triage_escalation_config(),
    )
    .await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board item create: {error}")))?;
    Ok(TaskBoardMutation {
        item: write.item,
        item_revision: write.item_revision,
        change_revision,
    })
}

async fn reject_if_item_exists_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<(), CliError> {
    if transaction.load_item_in_tx(item_id).await?.is_some() {
        return Err(db_error(format!(
            "task-board item '{item_id}' already exists"
        )));
    }
    Ok(())
}

/// Evaluate `BuiltInV1` against a just-inserted item and, only if it changed
/// status or placement, persist that through a follow-up automatic lane
/// transition. Returns the original insert write unchanged otherwise, so a
/// non-promoting create costs no extra revision bump. `suppress_placement`
/// carries the create request's own explicit status choice, the direct human
/// effect an update derives from a status field it just applied. A fresh
/// create never carries a manual placement, and the item did not exist a
/// moment ago, so it cannot carry a triage override yet -- no query needed to
/// know that.
async fn apply_triage_after_insert_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    inserted: LaneTransitionWrite,
    suppress_placement: bool,
) -> Result<(LaneTransitionWrite, Option<TriageOutcome>), CliError> {
    let before_triage = inserted.item.clone();
    let mut item = inserted.item.clone();
    let decided_at = utc_now();
    let outcome = Triage
        .apply_active_triage_in_tx(
            transaction,
            &mut item,
            &decided_at,
            suppress_placement,
            None,
        )
        .await?;
    if item == before_triage {
        return Ok((inserted, outcome));
    }
    let write = replace_with_lane_transition_in_tx(
        transaction,
        before_triage,
        inserted.item_revision,
        item,
        LaneTransitionKind::Automatic,
    )
    .await?;
    Ok((write, outcome))
}
