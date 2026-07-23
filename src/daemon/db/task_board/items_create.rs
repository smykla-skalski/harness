use sqlx::{Sqlite, Transaction};

use super::super::ITEMS_CHANGE_SCOPE;
use super::super::lane_order::{
    LaneTransitionKind, LaneTransitionWrite, insert_with_lane_transition_in_tx,
    replace_with_lane_transition_in_tx,
};
use super::super::triage_apply::{TriageOutcome, apply_builtin_v1_triage_in_tx};
use super::{
    TaskBoardMutation, TaskBoardMutationKind, TaskBoardTriageIngress, bump_change_in_tx,
    load_item_in_tx, record_triage_or_lane_audit_in_tx, validate_item,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::TaskBoardItem;

impl AsyncDaemonDb {
    /// Insert one new Task Board item. Never evaluates `BuiltInV1`: every
    /// internal lane/dispatch/workflow/migration/test-fixture constructor
    /// must keep using this method so an unrelated internal create can never
    /// become accidental triage ingress. The public create API and provider
    /// import use the `_with_triage` methods below instead.
    pub(crate) async fn create_task_board_item(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        self.create_task_board_item_impl(item, TaskBoardTriageIngress::None)
            .await
    }

    /// Like [`create_task_board_item`], but also evaluates `BuiltInV1` in the
    /// same transaction, for the public create API.
    pub(crate) async fn create_task_board_item_with_triage(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        self.create_task_board_item_impl(item, TaskBoardTriageIngress::HumanUpdate)
            .await
    }

    /// Like [`create_task_board_item`], but also evaluates `BuiltInV1` in the
    /// same transaction, for provider import.
    pub(crate) async fn create_task_board_item_with_provider_triage(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        self.create_task_board_item_impl(item, TaskBoardTriageIngress::ProviderReconcile)
            .await
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "sequential create/insert/triage/audit/commit steps, each already its own helper"
    )]
    async fn create_task_board_item_impl(
        &self,
        mut item: TaskBoardItem,
        ingress: TaskBoardTriageIngress,
    ) -> Result<TaskBoardMutation, CliError> {
        validate_item(&item)?;
        item.status = item.status.canonical_persisted_status();
        validate_item(&item)?;
        let mut transaction = self
            .begin_immediate_transaction("task board item create")
            .await?;
        reject_if_item_exists_in_tx(&mut transaction, &item.id).await?;
        let inserted = insert_with_lane_transition_in_tx(&mut transaction, item).await?;
        let before_triage = inserted.item.clone();
        let (write, outcome) = match ingress {
            TaskBoardTriageIngress::None => (inserted, None),
            TaskBoardTriageIngress::HumanUpdate | TaskBoardTriageIngress::ProviderReconcile => {
                apply_triage_after_insert_in_tx(&mut transaction, inserted).await?
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
}

async fn reject_if_item_exists_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<(), CliError> {
    if load_item_in_tx(transaction, item_id).await?.is_some() {
        return Err(db_error(format!(
            "task-board item '{item_id}' already exists"
        )));
    }
    Ok(())
}

/// Evaluate `BuiltInV1` against a just-inserted item and, only if it changed
/// status or placement, persist that through a follow-up automatic lane
/// transition. Returns the original insert write unchanged otherwise, so a
/// non-promoting create costs no extra revision bump. A fresh create never
/// has a manual placement or an explicit status signal (the create request
/// exposes neither), so placement is never suppressed here.
async fn apply_triage_after_insert_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    inserted: LaneTransitionWrite,
) -> Result<(LaneTransitionWrite, Option<TriageOutcome>), CliError> {
    let before_triage = inserted.item.clone();
    let mut item = inserted.item.clone();
    let decided_at = utc_now();
    let outcome = apply_builtin_v1_triage_in_tx(transaction, &mut item, &decided_at, false).await?;
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
