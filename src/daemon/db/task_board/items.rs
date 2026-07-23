use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::ITEMS_CHANGE_SCOPE;
use super::lane_order::{
    LaneTransitionKind, LaneTransitionWrite, record_lane_transition_audit_in_tx,
    replace_with_lane_transition_in_tx,
};
use super::mapper::item_from_rows;
use super::rows::{ExternalRefRow, ItemRow};
use super::triage_apply::{
    TriageOutcome, apply_builtin_v1_triage_in_tx,
    clear_stale_automatic_placement_on_human_status_move,
};
use super::triage_audit::{
    record_item_created_audit_in_tx, record_item_updated_audit_in_tx,
    record_triage_decided_audit_in_tx, record_triage_effect_reapplied_audit_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::errors::CliErrorKind;
use crate::infra::io;
use crate::task_board::types::{CURRENT_TASK_BOARD_ITEM_VERSION, MAX_TASK_BOARD_ESTIMATE};
use crate::task_board::{TaskBoardItem, TaskBoardStatus, validate_lane_placement};

#[path = "items_lifecycle.rs"]
mod lifecycle;
use lifecycle::ensure_estimates_are_editable_in_tx;
pub(super) use lifecycle::{
    apply_task_board_item_status_transition_in_tx, ensure_workflow_item_mutation_allowed_in_tx,
};

#[path = "items_parent.rs"]
mod parent;
use parent::{ensure_parent_assignment_is_valid_in_tx, next_child_order_in_tx};
pub(super) use parent::clear_children_parent_in_tx;

#[path = "items_write.rs"]
mod write;
pub(super) use write::{insert_item_in_tx, replace_item_in_tx};

#[path = "items_create.rs"]
mod create;

const SELECT_ITEM: &str = "SELECT * FROM task_board_items WHERE item_id = ?1";
const SELECT_REFS: &str = "SELECT item_id, position, provider, external_id, url, sync_state_json
    FROM task_board_external_refs WHERE item_id = ?1 ORDER BY position";

#[derive(Debug)]
pub(crate) struct TaskBoardMutation {
    pub(crate) item: TaskBoardItem,
    pub(crate) item_revision: i64,
    pub(crate) change_revision: i64,
}

#[derive(Debug, Clone)]
pub(crate) struct TaskBoardItemSnapshot {
    pub(crate) item: TaskBoardItem,
    pub(crate) item_revision: i64,
}

/// Which ingress point is driving a triage-evaluating update, so the same
/// same-call status/placement diff can mean different things: a direct
/// human override (suppresses placement) versus provider evidence arriving
/// through create/reconcile/restore (never suppresses on its own).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TaskBoardTriageIngress {
    None,
    HumanUpdate,
    ProviderReconcile,
}

/// Distinguishes a create from an update for the "ordinary mutation, no
/// triage outcome either way" audit case, so a create is never reported as
/// `task_board.item.updated`.
pub(super) enum TaskBoardMutationKind {
    Create,
    Update,
}

impl AsyncDaemonDb {
    /// Load one Task Board item, including tombstones.
    pub(crate) async fn task_board_item(&self, item_id: &str) -> Result<TaskBoardItem, CliError> {
        self.task_board_item_snapshot(item_id)
            .await
            .map(|snapshot| snapshot.item)
    }

    /// Load one Task Board item with the row revision used by automation CAS.
    pub(crate) async fn task_board_item_snapshot(
        &self,
        item_id: &str,
    ) -> Result<TaskBoardItemSnapshot, CliError> {
        io::validate_safe_segment(item_id)?;
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin task board item load: {error}")))?;
        let (item, item_revision) = load_item_in_tx(&mut transaction, item_id)
            .await?
            .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board item load: {error}")))?;
        Ok(TaskBoardItemSnapshot {
            item,
            item_revision,
        })
    }

    /// Like [`task_board_item`], but returns `Ok(None)` for a genuinely
    /// missing item instead of an error, so a caller that needs to
    /// distinguish "not found" from a real database failure -- a
    /// provider-exclusion restore deciding whether there is anything to
    /// restore, for example -- does not have to fail closed on every error
    /// alike.
    pub(crate) async fn find_task_board_item(
        &self,
        item_id: &str,
    ) -> Result<Option<TaskBoardItem>, CliError> {
        io::validate_safe_segment(item_id)?;
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin task board item load: {error}")))?;
        let found = load_item_in_tx(&mut transaction, item_id).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board item load: {error}")))?;
        Ok(found.map(|(item, _revision)| item))
    }

    /// List active Task Board items in the legacy stable ordering.
    pub(crate) async fn list_task_board_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        let mut items = self.list_task_board_items_including_deleted().await?;
        let status = status.map(TaskBoardStatus::canonical_persisted_status);
        items.retain(|item| {
            !item.is_deleted() && status.is_none_or(|expected| item.status == expected)
        });
        Ok(items)
    }

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
        reason = "pre-existing sequential mutation/guard chain; triage is one more straight-line step"
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
        let prior_parent_item_id = item.parent_item_id.clone();
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
        validate_item(&item)?;
        item.status = item.status.canonical_persisted_status();
        item.updated_at = utc_now();
        if item.parent_item_id != prior_parent_item_id {
            item.child_order = match item.parent_item_id.clone() {
                Some(parent_id) => {
                    ensure_parent_assignment_is_valid_in_tx(&mut transaction, item_id, &parent_id)
                        .await?;
                    next_child_order_in_tx(&mut transaction, &parent_id).await?
                }
                None => 0,
            };
        }
        apply_task_board_item_status_transition_in_tx(&mut transaction, &item).await?;
        if item.deleted_at.is_some() {
            clear_children_parent_in_tx(&mut transaction, item_id).await?;
        }
        if ingress == TaskBoardTriageIngress::HumanUpdate {
            clear_stale_automatic_placement_on_human_status_move(
                before.status.canonical_persisted_status(),
                &mut item,
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
                let suppress_placement = ingress == TaskBoardTriageIngress::HumanUpdate
                    && direct_effect_this_call;
                apply_builtin_v1_triage_in_tx(
                    &mut transaction,
                    &mut item,
                    &decided_at,
                    suppress_placement,
                )
                .await?
            }
        };
        let triage_changed_placement = item.status != pre_triage_item.status
            || item.lane_position != pre_triage_item.lane_position
            || item.lane_origin != pre_triage_item.lane_origin
            || item.lane_set_at != pre_triage_item.lane_set_at;
        let transition_kind = if triage_changed_placement {
            LaneTransitionKind::Automatic
        } else {
            LaneTransitionKind::Generic
        };
        let before_triage = before.clone();
        let write =
            replace_with_lane_transition_in_tx(&mut transaction, before, revision, item, transition_kind)
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

    /// Tombstone one Task Board item.
    pub(crate) async fn delete_task_board_item(
        &self,
        item_id: &str,
    ) -> Result<TaskBoardMutation, CliError> {
        self.update_task_board_item(item_id, |item| {
            item.deleted_at = Some(utc_now());
            item.tombstone_cause = Some(crate::task_board::TaskBoardTombstoneCause::Manual);
            Ok(true)
        })
        .await?
        .ok_or_else(|| db_error("task board delete unexpectedly produced no mutation"))
    }
}

/// Records exactly one audit event for a write, distinguishing: a fresh
/// `BuiltInV1` decision; an existing decision whose placement effect was
/// merely reapplied (never reported as a fresh decision); an ordinary public
/// mutation through the human or provider ingress paths that produced
/// neither (always audited, even when the lane tuple did not change, so a
/// public no-op is never silently unaudited); and a plain internal
/// lane-only mutation, which keeps the old no-audit-when-unchanged behavior
/// since internal call sites own their own audits elsewhere.
async fn record_triage_or_lane_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: &TaskBoardItem,
    outcome: Option<&TriageOutcome>,
    mutation_kind: Option<TaskBoardMutationKind>,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
) -> Result<(), CliError> {
    match outcome {
        Some(TriageOutcome::Decided(decision)) => {
            record_triage_decided_audit_in_tx(transaction, before, decision, write, items_change_seq)
                .await
        }
        Some(TriageOutcome::RetainedEffect(decision)) => {
            record_triage_effect_reapplied_audit_in_tx(
                transaction,
                before,
                decision,
                write,
                items_change_seq,
            )
            .await
        }
        None => match mutation_kind {
            Some(TaskBoardMutationKind::Create) => {
                record_item_created_audit_in_tx(transaction, write, items_change_seq).await
            }
            Some(TaskBoardMutationKind::Update) => {
                record_item_updated_audit_in_tx(transaction, write, items_change_seq).await
            }
            None => record_lane_transition_audit_in_tx(transaction, write, items_change_seq).await,
        },
    }
}

pub(super) async fn load_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<Option<(TaskBoardItem, i64)>, CliError> {
    let Some(row) = query_as::<_, ItemRow>(SELECT_ITEM)
        .bind(item_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task board item '{item_id}': {error}")))?
    else {
        return Ok(None);
    };
    let refs = query_as::<_, ExternalRefRow>(SELECT_REFS)
        .bind(item_id)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task board refs '{item_id}': {error}")))?;
    item_from_rows(row, refs).map(Some)
}

pub(super) async fn bump_change_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    scope: &str,
) -> Result<i64, CliError> {
    query("UPDATE change_tracking_state SET last_seq = last_seq + 1 WHERE singleton = 1")
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("advance task board change sequence: {error}")))?;
    let change_seq =
        query_scalar::<_, i64>("SELECT last_seq FROM change_tracking_state WHERE singleton = 1")
            .fetch_one(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("read task board change sequence: {error}")))?;
    query(
        "INSERT INTO change_tracking (scope, version, updated_at, change_seq)
        VALUES (?1, 1, ?2, ?3)
        ON CONFLICT(scope) DO UPDATE SET version = version + 1,
        updated_at = excluded.updated_at, change_seq = excluded.change_seq",
    )
    .bind(scope)
    .bind(utc_now())
    .bind(change_seq)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("record task board change: {error}")))?;
    Ok(change_seq)
}

pub(super) async fn items_change_sequence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<i64, CliError> {
    query_scalar("SELECT COALESCE(change_seq, 0) FROM change_tracking WHERE scope = ?1")
        .bind(ITEMS_CHANGE_SCOPE)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| {
            db_error(format!(
                "read task-board item sequence in transaction: {error}"
            ))
        })
        .map(|sequence| sequence.unwrap_or(0))
}

pub(super) fn validate_item(item: &TaskBoardItem) -> Result<(), CliError> {
    io::validate_safe_segment(&item.id)?;
    if item.schema_version != CURRENT_TASK_BOARD_ITEM_VERSION {
        return Err(CliErrorKind::workflow_version(format!(
            "task-board item '{}' uses unsupported schema v{}",
            item.id, item.schema_version
        ))
        .into());
    }
    if item.title.trim().is_empty() {
        return Err(db_error(format!(
            "task-board item '{}' must have a non-blank title",
            item.id
        )));
    }
    if item
        .estimated_tokens
        .is_some_and(|value| !(1..=MAX_TASK_BOARD_ESTIMATE).contains(&value))
    {
        return Err(db_error("task-board estimated tokens are out of range"));
    }
    if item
        .estimated_cost_microusd
        .is_some_and(|value| !(1..=MAX_TASK_BOARD_ESTIMATE).contains(&value))
    {
        return Err(db_error("task-board estimated cost is out of range"));
    }
    if item.parent_item_id.as_deref() == Some(item.id.as_str()) {
        return Err(db_error(format!(
            "task-board item '{}' cannot be its own parent",
            item.id
        )));
    }
    validate_lane_placement(item).map_err(db_error)?;
    Ok(())
}
