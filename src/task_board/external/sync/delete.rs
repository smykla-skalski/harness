use crate::errors::CliError;
use crate::task_board::external::{
    ExternalProvider, ExternalSyncClient, ExternalSyncField, ExternalTaskRef,
};
use crate::task_board::store::TaskBoardStore;
use crate::task_board::types::TaskBoardItem;

use super::{
    ExternalSyncAction, ExternalSyncOperation, ExternalSyncOptions, OperationDraft, operation,
    provider_ref, run_board_blocking,
};

pub(super) async fn delete_remote_tombstones(
    board: &TaskBoardStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    if !client.allows_delete() {
        return Ok(());
    }
    let provider = client.provider();
    let tombstones = run_board_blocking(board, "list tombstones", |board| {
        board.list_including_deleted().map(|items| {
            items
                .into_iter()
                .filter(|item| item.is_deleted() && !item.external_refs.is_empty())
                .collect::<Vec<_>>()
        })
    })
    .await?;
    for item in tombstones {
        let Some(reference) = provider_ref(&item, provider) else {
            continue;
        };
        operations.push(operation(tombstone_draft(
            provider,
            &item,
            reference.clone(),
            options,
        )));
        if options.dry_run {
            continue;
        }
        client.delete_task(&item, &reference).await?;
    }
    Ok(())
}

fn tombstone_draft(
    provider: ExternalProvider,
    item: &TaskBoardItem,
    reference: ExternalTaskRef,
    options: ExternalSyncOptions,
) -> OperationDraft {
    OperationDraft {
        provider,
        action: ExternalSyncAction::Delete,
        board_item_id: Some(item.id.clone()),
        reference,
        dry_run: options.dry_run,
        applied: !options.dry_run,
        changed_fields: vec![ExternalSyncField::Status],
        unsupported_fields: Vec::new(),
    }
}
