use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::task_board::external::TaskBoardSyncItemSnapshot;
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{
    ProviderExclusionAuditContext, ProviderExclusionRestoreOutcome, TaskBoardItem,
    TaskBoardSyncConflict,
};

/// Tombstones an already-visible, pre-dispatch item because the provider now
/// reports an exclusion label. Thin delegation to the dedicated DB-layer
/// method, which owns eligibility (pre-dispatch, no active dispatch
/// admission, exact `expected_revision` CAS) and its own one-and-only-one
/// audit event in the same transaction as the tombstone.
pub(super) async fn hide_for_provider_exclusion(
    db: &AsyncDaemonDb,
    item_id: &str,
    expected_revision: i64,
    patch: TaskBoardItemPatch,
    context: &ProviderExclusionAuditContext,
    conflicts: Option<Vec<TaskBoardSyncConflict>>,
) -> Result<Option<TaskBoardItem>, CliError> {
    db.hide_task_board_item_for_provider_exclusion(
        item_id,
        expected_revision,
        patch,
        context,
        conflicts,
    )
    .await
    .map(|mutation| mutation.map(|mutation| mutation.item))
}

/// Restores a previously provider-exclusion-tombstoned item because the
/// provider no longer reports an exclusion label. Thin delegation to the
/// dedicated DB-layer method, which owns the CAS against `expected`, parent
/// resolution in the same transaction, retained-decision reconciliation, and
/// its own one-and-only-one audit event.
pub(super) async fn restore_from_provider_exclusion(
    db: &AsyncDaemonDb,
    expected: TaskBoardSyncItemSnapshot,
    patch: TaskBoardItemPatch,
    context: &ProviderExclusionAuditContext,
    conflicts: Option<Vec<TaskBoardSyncConflict>>,
) -> Result<ProviderExclusionRestoreOutcome, CliError> {
    db.restore_task_board_item_for_provider_exclusion(
        &expected.item.id,
        expected.item_revision,
        patch,
        context,
        conflicts,
    )
    .await
}
