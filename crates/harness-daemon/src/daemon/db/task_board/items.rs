//! Item mutation: the create/update/delete surface for one Task Board item
//! row, including the CAS revision and item-list change sequence every
//! write bumps. The seam with triage evaluation is deliberately narrow and
//! asymmetric, so each side can move into its own crate later without
//! carrying the other with it. Forward (this module calling into triage):
//! [`TriageEvaluator`] (declared in the nested `triage_evaluator` module,
//! implemented by [`super::triage_interface::Triage`]) is the only thing
//! item mutation depends on -- never triage's files by name. Reverse
//! (triage calling into this module): triage's own entry points
//! (`triage_apply_agent.rs`'s agent-verdict endpoint,
//! `triage_override/mutations.rs`'s override set/clear,
//! `triage_rules_reevaluation.rs`'s bulk rule-set-activation pass) import
//! `bump_change_in_tx`, `load_item_with_triage_override_in_tx`, and
//! [`apply_task_board_item_status_transition_in_tx`] directly instead of
//! through a trait -- item mutation is the lower layer every task-board
//! area, triage included, already depends on this way, so that direction
//! needs no inversion.

use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::ITEMS_CHANGE_SCOPE;
use super::item_tx_ext::TaskBoardItemTxExt;
use super::lane_order::{LaneTransitionWrite, record_lane_transition_audit_in_tx};
use super::mapper::item_from_rows;
use super::rows::{ExternalRefRow, ItemRow};
use super::items_reads;
use super::triage_interface::Triage;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::infra::io;
use crate::task_board::TaskBoardTombstoneCause;
use crate::task_board::types::{CURRENT_TASK_BOARD_ITEM_VERSION, MAX_TASK_BOARD_ESTIMATE};
use crate::task_board::{
    TaskBoardItem, TaskBoardStatus, TaskBoardTriageEscalationConfig, TaskBoardTriageOverride,
    validate_lane_placement,
};
use harness_kernel::errors::CliErrorKind;

#[path = "items_audit.rs"]
mod audit;
use audit::{record_item_created_audit_in_tx, record_item_updated_audit_in_tx};

#[path = "items_triage_interface.rs"]
mod triage_evaluator;
pub(super) use triage_evaluator::{TriageEvaluator, TriageOutcome};

#[path = "items_lifecycle.rs"]
mod lifecycle;
pub(super) use lifecycle::{
    apply_task_board_item_status_transition_in_tx, ensure_workflow_item_mutation_allowed_in_tx,
};

#[path = "items_parent.rs"]
mod parent;
pub(super) use parent::{
    ParentAssignmentValidation, check_parent_assignment_in_tx, clear_children_parent_in_tx,
    next_child_order_in_tx,
};

#[path = "items_write.rs"]
mod write;
pub(super) use write::{insert_item_in_tx, replace_item_in_tx};

#[path = "items_create.rs"]
pub(crate) mod create;

#[path = "items_update.rs"]
pub(crate) mod update;

const SELECT_ITEM: &str = "SELECT * FROM task_board_items WHERE item_id = ?1";
const SELECT_REFS: &str = "SELECT item_id, position, provider, external_id, url, sync_state_json
    FROM task_board_external_refs WHERE item_id = ?1 ORDER BY position";

// `pub`, not `pub(crate)`: `tests/integration_daemon.rs`'s task-board sync
// scenarios read `item_revision` off a live mutation/snapshot the same way
// this crate's own unit tests do, and that binary sees only `pub` items.
#[derive(Debug)]
pub struct TaskBoardMutation {
    pub item: TaskBoardItem,
    pub item_revision: i64,
    pub change_revision: i64,
}

#[derive(Debug, Clone)]
pub struct TaskBoardItemSnapshot {
    pub item: TaskBoardItem,
    pub item_revision: i64,
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

pub(crate) async fn task_board_item(
    db: &AsyncDaemonDb,
    item_id: &str,
) -> Result<TaskBoardItem, CliError> {
    task_board_item_snapshot(db, item_id)
        .await
        .map(|snapshot| snapshot.item)
}

pub(crate) async fn task_board_item_snapshot(
    db: &AsyncDaemonDb,
    item_id: &str,
) -> Result<TaskBoardItemSnapshot, CliError> {
    io::validate_safe_segment(item_id)?;
    let mut transaction = db
        .pool()
        .begin()
        .await
        .map_err(|error| db_error(format!("begin task board item load: {error}")))?;
    let (item, item_revision) = transaction
        .load_item_in_tx(item_id)
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

pub(crate) async fn find_task_board_item(
    db: &AsyncDaemonDb,
    item_id: &str,
) -> Result<Option<TaskBoardItem>, CliError> {
    io::validate_safe_segment(item_id)?;
    let mut transaction = db
        .pool()
        .begin()
        .await
        .map_err(|error| db_error(format!("begin task board item load: {error}")))?;
    let found = transaction.load_item_in_tx(item_id).await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board item load: {error}")))?;
    Ok(found.map(|(item, _revision)| item))
}

pub(crate) async fn list_task_board_items(
    db: &AsyncDaemonDb,
    status: Option<TaskBoardStatus>,
) -> Result<Vec<TaskBoardItem>, CliError> {
    let mut items = items_reads::list_task_board_items_including_deleted(db).await?;
    let status = status.map(TaskBoardStatus::canonical_persisted_status);
    items.retain(|item| !item.is_deleted() && status.is_none_or(|expected| item.status == expected));
    Ok(items)
}

pub(crate) async fn delete_task_board_item(
    db: &AsyncDaemonDb,
    item_id: &str,
) -> Result<TaskBoardMutation, CliError> {
    update::update_task_board_item(db, item_id, |item| {
        item.deleted_at = Some(utc_now());
        item.tombstone_cause = Some(TaskBoardTombstoneCause::Manual);
        Ok(true)
    })
    .await?
    .ok_or_else(|| db_error("task board delete unexpectedly produced no mutation"))
}

/// Records exactly one audit event for a write, distinguishing: a fresh
/// `BuiltInV1` decision; an existing decision whose placement effect was
/// merely reapplied (never reported as a fresh decision); an ordinary public
/// mutation through the human or provider ingress paths that produced
/// neither (always audited, even when the lane tuple did not change, so a
/// public no-op is never silently unaudited); and a plain internal
/// lane-only mutation, which keeps the old no-audit-when-unchanged behavior
/// since internal call sites own their own audits elsewhere.
#[expect(
    clippy::too_many_arguments,
    reason = "the escalation eligibility fields are only needed on the Decided branch, but every \
              ingress call site already has all of them in hand"
)]
async fn record_triage_or_lane_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: &TaskBoardItem,
    outcome: Option<&TriageOutcome>,
    mutation_kind: Option<TaskBoardMutationKind>,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
    override_active: bool,
    escalation_config: &TaskBoardTriageEscalationConfig,
) -> Result<(), CliError> {
    match outcome {
        Some(TriageOutcome::Decided(decision)) => {
            Triage
                .maybe_enqueue_triage_escalation_in_tx(
                    transaction,
                    &before.id,
                    decision,
                    override_active,
                    escalation_config,
                    &decision.decided_at,
                )
                .await?;
            Triage
                .record_triage_decided_audit_in_tx(
                    transaction,
                    before,
                    decision,
                    write,
                    items_change_seq,
                )
                .await
        }
        Some(TriageOutcome::RetainedEffect(decision)) => {
            Triage
                .record_triage_effect_reapplied_audit_in_tx(
                    transaction,
                    before,
                    decision,
                    write,
                    items_change_seq,
                )
                .await
        }
        None => {
            record_untriaged_mutation_audit_in_tx(
                transaction,
                mutation_kind,
                write,
                items_change_seq,
            )
            .await
        }
    }
}

/// Audit a mutation that produced no triage outcome at all: a create, a plain
/// update, or an internal lane-only move whose own call site owns whatever
/// further audit it needs.
async fn record_untriaged_mutation_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    mutation_kind: Option<TaskBoardMutationKind>,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
) -> Result<(), CliError> {
    match mutation_kind {
        Some(TaskBoardMutationKind::Create) => {
            record_item_created_audit_in_tx(transaction, write, items_change_seq).await
        }
        Some(TaskBoardMutationKind::Update) => {
            record_item_updated_audit_in_tx(transaction, write, items_change_seq).await
        }
        None => record_lane_transition_audit_in_tx(transaction, write, items_change_seq).await,
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn resolve_parent_update_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    before: &TaskBoardItem,
    ingress: TaskBoardTriageIngress,
) -> Result<(), CliError> {
    if item.parent_item_id == before.parent_item_id {
        return Ok(());
    }
    let Some(parent_id) = item.parent_item_id.clone() else {
        item.child_order = 0;
        return Ok(());
    };
    match transaction
        .check_parent_assignment_in_tx(&item.id, &parent_id)
        .await?
    {
        ParentAssignmentValidation::Valid => {
            item.child_order = transaction.next_child_order_in_tx(&parent_id).await?;
            Ok(())
        }
        ParentAssignmentValidation::Invalid(reason)
            if ingress == TaskBoardTriageIngress::ProviderReconcile =>
        {
            tracing::warn!(
                item_id = %item.id,
                parent_id,
                reason,
                "task-board provider reconcile rejected parent link"
            );
            item.parent_item_id.clone_from(&before.parent_item_id);
            item.child_order = before.child_order;
            Ok(())
        }
        ParentAssignmentValidation::Invalid(reason) => Err(db_error(reason)),
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

/// Like [`load_item_in_tx`], but also returns the item's active triage
/// override, decoded from the same already-fetched row instead of a second
/// round trip -- `SELECT_ITEM` already reads every column on this row, so a
/// caller that needs both the item and its override (triage evaluation, an
/// override set/clear) gets them from one query.
pub(super) async fn load_item_with_triage_override_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<Option<(TaskBoardItem, i64, Option<TaskBoardTriageOverride>)>, CliError> {
    let Some(row) = query_as::<_, ItemRow>(SELECT_ITEM)
        .bind(item_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task board item '{item_id}': {error}")))?
    else {
        return Ok(None);
    };
    let override_ = Triage.triage_override_from_item_row(&row)?;
    let refs = query_as::<_, ExternalRefRow>(SELECT_REFS)
        .bind(item_id)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task board refs '{item_id}': {error}")))?;
    let (item, revision) = item_from_rows(row, refs)?;
    Ok(Some((item, revision, override_)))
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
