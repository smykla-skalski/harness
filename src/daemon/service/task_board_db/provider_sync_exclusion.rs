use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::task_board::{TaskBoardItem, TaskBoardTombstoneCause};

/// Tombstones an already-visible, pre-dispatch item because the provider now
/// reports an exclusion label. Thin delegation to the dedicated DB-layer
/// method, which owns eligibility (pre-dispatch, no active dispatch
/// admission) and its own one-and-only-one audit event in the same
/// transaction as the tombstone.
pub(super) async fn hide_for_provider_exclusion(
    db: &AsyncDaemonDb,
    item_id: &str,
) -> Result<Option<TaskBoardItem>, CliError> {
    db.hide_task_board_item_for_provider_exclusion(item_id)
        .await
        .map(|mutation| mutation.map(|mutation| mutation.item))
}

/// Restores a previously provider-exclusion-tombstoned item because the
/// provider no longer reports an exclusion label, refreshing every
/// provider-owned create field from `revived` (built by the caller from the
/// current provider task via `create_item_from_external`, same deterministic
/// id). A single indexed point lookup decides whether there is anything to
/// restore at all, so a normal (and far more common) fresh create never
/// pays for a full board scan.
pub(super) async fn restore_from_provider_exclusion(
    db: &AsyncDaemonDb,
    revived: TaskBoardItem,
) -> Result<Option<TaskBoardItem>, CliError> {
    let item_id = revived.id.clone();
    let Some(stored) = db.find_task_board_item(&item_id).await? else {
        return Ok(None);
    };
    if stored.tombstone_cause != Some(TaskBoardTombstoneCause::ProviderExclusion) {
        return Ok(None);
    }
    let mutation = db
        .update_task_board_item_with_provider_triage(&item_id, move |item| {
            if item.tombstone_cause != Some(TaskBoardTombstoneCause::ProviderExclusion) {
                return Ok(false);
            }
            item.deleted_at = None;
            item.tombstone_cause = None;
            item.title = revived.title;
            item.body = revived.body;
            item.status = revived.status;
            item.tags = revived.tags;
            item.project_id = revived.project_id;
            item.execution_repository = revived.execution_repository;
            item.external_refs = revived.external_refs;
            item.kind = revived.kind;
            item.imported_from_provider = revived.imported_from_provider;
            item.planning = revived.planning;
            Ok(true)
        })
        .await?;
    Ok(mutation.map(|mutation| mutation.item))
}
