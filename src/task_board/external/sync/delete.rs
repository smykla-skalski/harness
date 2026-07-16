use crate::task_board::external::{
    ExternalProvider, ExternalProviderScopeAttempt, ExternalSyncClient, ExternalSyncField,
    ExternalTaskRef,
};
use crate::task_board::types::TaskBoardItem;

use super::{
    ExternalSyncAction, ExternalSyncOperation, ExternalSyncOptions, OperationDraft,
    SyncClientError, TaskBoardSyncStore, client_owns_item, operation, provider_ref,
};

pub(super) async fn delete_remote_tombstones(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), SyncClientError> {
    if !client.allows_delete() {
        return Ok(());
    }
    let provider = client.provider();
    let scope_id = client.scope_id();
    let tombstones = board
        .list_items_including_deleted()
        .await
        .map_err(SyncClientError::Local)?
        .into_iter()
        .filter(|item| {
            item.is_deleted()
                && !item.external_refs.is_empty()
                && client_owns_item(client, item, &scope_id)
        })
        .collect::<Vec<_>>();
    for item in tombstones {
        let Some(reference) = provider_ref(&item, provider) else {
            continue;
        };
        if options.dry_run {
            operations.push(operation(tombstone_draft(
                provider, &item, reference, options,
            )));
            continue;
        }
        super::scope::renew_scope_attempt(board, attempt).await?;
        client
            .delete_task(&item, &reference)
            .await
            .map_err(SyncClientError::Provider)?;
        operations.push(operation(tombstone_draft(
            provider, &item, reference, options,
        )));
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
