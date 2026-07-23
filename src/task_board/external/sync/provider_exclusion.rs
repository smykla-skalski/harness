use crate::errors::CliError;
use crate::task_board::external::{ExternalProvider, ExternalSyncField, ExternalTask};
use crate::task_board::types::TaskBoardItem;

use super::{
    ExternalSyncAction, ExternalSyncOperation, ExternalSyncOptions, OperationDraft,
    TaskBoardSyncStore, create_item_from_external, operation,
};

/// Tombstones an already-visible, pre-dispatch item because the provider now
/// reports an exclusion label. A no-op record (nothing pushed to
/// `operations`) when the item is no longer eligible to be hidden this way
/// (already claimed or dispatched), preserving in-flight work untouched.
pub(super) async fn hide_existing_item_for_exclusion(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    item: &TaskBoardItem,
    task: ExternalTask,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    if options.dry_run {
        operations.push(operation(OperationDraft {
            provider,
            action: ExternalSyncAction::Pull,
            board_item_id: Some(item.id.clone()),
            reference: task.reference,
            dry_run: true,
            applied: false,
            changed_fields: vec![ExternalSyncField::Status],
            unsupported_fields: Vec::new(),
        }));
        return Ok(());
    }
    let hidden = board.hide_for_provider_exclusion(&item.id).await?;
    if hidden.is_some() {
        operations.push(operation(OperationDraft {
            provider,
            action: ExternalSyncAction::Pull,
            board_item_id: Some(item.id.clone()),
            reference: task.reference,
            dry_run: false,
            applied: true,
            changed_fields: vec![ExternalSyncField::Status],
            unsupported_fields: Vec::new(),
        }));
    }
    Ok(())
}

/// A "new" provider task whose deterministic id already exists, tombstoned
/// for provider exclusion, means the provider un-excluded it: restore it
/// with fresh field values instead of colliding with the stored id on
/// create. Not eligible restores (no tombstone at that id, or tombstoned
/// some other way) fall through to a normal create.
pub(super) async fn try_restore_provider_exclusion_tombstone(
    board: &dyn TaskBoardSyncStore,
    task: &ExternalTask,
) -> Result<Option<TaskBoardItem>, CliError> {
    board
        .restore_from_provider_exclusion(create_item_from_external(task))
        .await
}

#[cfg(test)]
mod tests;
