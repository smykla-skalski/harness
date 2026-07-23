use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::infra::io;
use crate::task_board::TaskBoardItem;

use super::super::ITEMS_CHANGE_SCOPE;
use super::super::lane_order::{LaneTransitionKind, replace_with_lane_transition_in_tx};
use super::super::triage_apply::{
    TriageOutcome, apply_builtin_v1_triage_in_tx,
    clear_stale_automatic_placement_on_human_status_move,
};
use super::lifecycle::ensure_estimates_are_editable_in_tx;
use super::{
    TaskBoardMutation, TaskBoardMutationKind, TaskBoardTriageIngress,
    apply_task_board_item_status_transition_in_tx, bump_change_in_tx, clear_children_parent_in_tx,
    load_item_in_tx, record_triage_or_lane_audit_in_tx, resolve_parent_update_in_tx, validate_item,
};

impl AsyncDaemonDb {
    /// Atomically load and conditionally mutate one Task Board item. Never
    /// evaluates `BuiltInV1`: every internal workflow/lifecycle mutation
    /// (dispatch, planning, estimates, reviews, GitHub projection, ...) must
    /// keep using this method so unrelated writes can never become
    /// accidental triage ingress. The public update API and provider
    /// create/reconcile/restore use the `_with_triage` methods below
    /// instead.
    pub(crate) async fn update_task_board_item<F>(
        &self,
        item_id: &str,
        mutate: F,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
    {
        self.update_task_board_item_impl(item_id, mutate, TaskBoardTriageIngress::None)
            .await
    }

    /// Like [`update_task_board_item`], but also evaluates `BuiltInV1` in the
    /// same transaction, for the public update API: a same-call status or
    /// placement change is a direct human effect and suppresses `BuiltInV1`
    /// placement (decision history still refreshes).
    pub(crate) async fn update_task_board_item_with_triage<F>(
        &self,
        item_id: &str,
        mutate: F,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
    {
        self.update_task_board_item_impl(item_id, mutate, TaskBoardTriageIngress::HumanUpdate)
            .await
    }

    /// Like [`update_task_board_item_with_triage`], but for provider
    /// create/reconcile/restore: a same-call status or placement change
    /// reflects provider evidence, not a human override, so it never
    /// suppresses `BuiltInV1` placement on its own. Only a pre-existing
    /// manual lane anchor still suppresses.
    pub(crate) async fn update_task_board_item_with_provider_triage<F>(
        &self,
        item_id: &str,
        mutate: F,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
    {
        self.update_task_board_item_impl(item_id, mutate, TaskBoardTriageIngress::ProviderReconcile)
            .await
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "sequential mutation and guard chain with atomic triage and lane persistence"
    )]
    async fn update_task_board_item_impl<F>(
        &self,
        item_id: &str,
        mutate: F,
        ingress: TaskBoardTriageIngress,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
    {
        io::validate_safe_segment(item_id)?;
        let mut transaction = self
            .begin_immediate_transaction("task board item update")
            .await?;
        let (mut item, revision) = load_item_in_tx(&mut transaction, item_id)
            .await?
            .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
        let before = item.clone();
        let prior_estimates = (item.estimated_tokens, item.estimated_cost_microusd);
        if !mutate(&mut item)? {
            transaction
                .commit()
                .await
                .map_err(|error| db_error(format!("commit task board item no-op: {error}")))?;
            return Ok(None);
        }
        if item.id != item_id {
            return Err(db_error(format!(
                "task-board mutation cannot change item id '{item_id}' to '{}'",
                item.id
            )));
        }
        if prior_estimates != (item.estimated_tokens, item.estimated_cost_microusd) {
            ensure_estimates_are_editable_in_tx(&mut transaction, item_id).await?;
        }
        item.status = item.status.canonical_persisted_status();
        resolve_parent_update_in_tx(&mut transaction, &mut item, &before, ingress).await?;
        validate_item(&item)?;
        if item == before {
            transaction
                .commit()
                .await
                .map_err(|error| db_error(format!("commit task board item no-op: {error}")))?;
            return Ok(None);
        }
        item.updated_at = utc_now();
        apply_task_board_item_status_transition_in_tx(&mut transaction, &item).await?;
        if item.deleted_at.is_some() {
            clear_children_parent_in_tx(&mut transaction, item_id).await?;
        }
        let (outcome, transition_kind) =
            apply_update_triage_in_tx(&mut transaction, &before, &mut item, ingress).await?;
        let before_triage = before.clone();
        let write = replace_with_lane_transition_in_tx(
            &mut transaction,
            before,
            revision,
            item,
            transition_kind,
        )
        .await?;
        let change_revision = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        let mutation_kind =
            (ingress != TaskBoardTriageIngress::None).then_some(TaskBoardMutationKind::Update);
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
            .map_err(|error| db_error(format!("commit task board item update: {error}")))?;
        Ok(Some(TaskBoardMutation {
            item: write.item,
            item_revision: write.item_revision,
            change_revision,
        }))
    }
}

async fn apply_update_triage_in_tx(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    before: &TaskBoardItem,
    item: &mut TaskBoardItem,
    ingress: TaskBoardTriageIngress,
) -> Result<(Option<TriageOutcome>, LaneTransitionKind), CliError> {
    if ingress == TaskBoardTriageIngress::HumanUpdate {
        clear_stale_automatic_placement_on_human_status_move(
            before.status.canonical_persisted_status(),
            item,
        );
    }
    let pre_triage_item = item.clone();
    let outcome = match ingress {
        TaskBoardTriageIngress::None => None,
        TaskBoardTriageIngress::HumanUpdate | TaskBoardTriageIngress::ProviderReconcile => {
            let decided_at = item.updated_at.clone();
            let direct_effect_this_call = before.status != item.status
                || before.lane_position != item.lane_position
                || before.lane_origin != item.lane_origin;
            let suppress_placement =
                ingress == TaskBoardTriageIngress::HumanUpdate && direct_effect_this_call;
            apply_builtin_v1_triage_in_tx(transaction, item, &decided_at, suppress_placement)
                .await?
        }
    };
    let changed_placement = item.status != pre_triage_item.status
        || item.lane_position != pre_triage_item.lane_position
        || item.lane_origin != pre_triage_item.lane_origin
        || item.lane_set_at != pre_triage_item.lane_set_at;
    let transition_kind = if changed_placement {
        LaneTransitionKind::Automatic
    } else {
        LaneTransitionKind::Generic
    };
    Ok((outcome, transition_kind))
}
