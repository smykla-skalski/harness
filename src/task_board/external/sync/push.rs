use crate::errors::{CliError, CliErrorKind};
use crate::github_api::republish_current_data_change;
use crate::task_board::external::ExternalProviderScopeAttempt;
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::types::{TaskBoardItem, TaskBoardStatus};

use super::conflicts::build_sync_conflicts;
use super::create_recovery::create_item_durably;
use super::lookup::{OperationDraft, operation, provider_ref};
use super::merge::{
    has_reported_conflict, local_update_fields, matching_ref, push_create_fields,
    replace_synced_ref, split_supported_fields,
};
use super::{
    ExternalProvider, ExternalSyncAction, ExternalSyncClient, ExternalSyncField,
    ExternalSyncOperation, ExternalSyncOptions, ExternalTask, ExternalTaskRef, ExternalTaskUpdate,
    ExternalUpdateOutcome, SyncClientError, TaskBoardExternalCreateIntent, TaskBoardSyncStore,
    canonical_external_status,
};

pub(super) async fn push_board_tasks(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<bool, SyncClientError> {
    let items = board
        .list_items(options.status)
        .await
        .map_err(SyncClientError::Local)?;
    let scope_id = client.scope_id();
    let mut created = false;
    for item in &items {
        created |= push_board_item(
            board, options, client, attempt, item, &scope_id, operations, follow_ups,
        )
        .await?;
    }
    Ok(created)
}

#[expect(
    clippy::too_many_arguments,
    reason = "one item push needs the admitted scope plus operation and durable follow-up sinks"
)]
async fn push_board_item(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    item: &TaskBoardItem,
    scope_id: &str,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<bool, SyncClientError> {
    if !super::client_owns_item(client, item, scope_id)
        || has_reported_conflict(operations, client.provider(), &item.id)
    {
        return Ok(false);
    }
    if let Some(reference) = provider_ref(item, client.provider()) {
        update_linked_remote(board, options, client, attempt, item, reference, operations)
            .await
            .map(|()| false)
    } else {
        create_remote_item(
            board, options, client, attempt, item, operations, follow_ups,
        )
        .await
    }
}

async fn create_remote_item(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    item: &TaskBoardItem,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<bool, SyncClientError> {
    let changed_fields = push_create_fields(item, client.provider());
    if options.dry_run {
        operations.push(push_operation(
            client.provider(),
            item,
            ExternalTaskRef::new(client.provider(), ""),
            true,
            false,
            changed_fields,
            Vec::new(),
        ));
        return Ok(false);
    }
    let Some(attempt) = attempt else {
        return Err(SyncClientError::Local(
            CliErrorKind::workflow_io("durable provider create requires a persisted scope attempt")
                .into(),
        ));
    };
    let result = create_item_durably(board, client, attempt, item, operations, follow_ups).await?;
    let Some(linked) = result.linked_item else {
        return Ok(result.durable_create);
    };
    republish_github_board_ready(client.provider());
    if linked.status == TaskBoardStatus::Done {
        let reference = provider_ref(&linked, client.provider()).ok_or_else(|| {
            SyncClientError::Local(
                CliErrorKind::concurrent_modification(
                    "finalized provider create has no linked reference",
                )
                .into(),
            )
        })?;
        update_linked_remote(
            board,
            options,
            client,
            Some(attempt),
            &linked,
            reference,
            operations,
        )
        .await?;
    }
    Ok(result.durable_create)
}

async fn update_linked_remote(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    item: &TaskBoardItem,
    reference: ExternalTaskRef,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), SyncClientError> {
    let capabilities = client.capabilities();
    let changed = local_update_fields(item, &reference, &capabilities);
    if changed.is_empty() {
        return Ok(());
    }
    let (supported, unsupported) = split_supported_fields(&changed, &capabilities);
    if options.dry_run || supported.is_empty() {
        operations.push(push_operation(
            client.provider(),
            item,
            reference,
            options.dry_run,
            false,
            supported,
            unsupported,
        ));
        return Ok(());
    }
    let Some(applied) = execute_provider_update(
        board, client, attempt, item, &reference, &supported, operations,
    )
    .await?
    else {
        return Ok(());
    };
    persist_linked_update(
        board,
        client,
        item,
        reference,
        applied,
        supported,
        unsupported,
        operations,
    )
    .await
}

struct AppliedRemoteUpdate {
    reference: ExternalTaskRef,
    provider_revision: Option<String>,
}

async fn execute_provider_update(
    board: &dyn TaskBoardSyncStore,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    item: &TaskBoardItem,
    reference: &ExternalTaskRef,
    supported: &[ExternalSyncField],
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<Option<AppliedRemoteUpdate>, SyncClientError> {
    let precondition = remote_precondition(item, reference);
    let update =
        ExternalTaskUpdate::new(supported.to_vec()).with_precondition_updated_at(precondition);
    super::scope::renew_scope_attempt(board, attempt).await?;
    let outcome = client
        .update_task(item, reference, update)
        .await
        .map_err(SyncClientError::Provider)?;
    match outcome {
        ExternalUpdateOutcome::Applied {
            reference,
            provider_revision,
        } => Ok(Some(AppliedRemoteUpdate {
            reference,
            provider_revision,
        })),
        ExternalUpdateOutcome::PreconditionFailed { current } => {
            persist_push_conflicts(board, item, &current, supported)
                .await
                .map_err(SyncClientError::Local)?;
            operations.push(operation(OperationDraft {
                provider: client.provider(),
                action: ExternalSyncAction::Conflict,
                board_item_id: Some(item.id.clone()),
                reference: current.reference,
                dry_run: false,
                applied: false,
                changed_fields: supported.to_vec(),
                unsupported_fields: Vec::new(),
            }));
            Ok(None)
        }
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "local persistence needs the exact provider result and operation evidence"
)]
async fn persist_linked_update(
    board: &dyn TaskBoardSyncStore,
    client: &dyn ExternalSyncClient,
    item: &TaskBoardItem,
    reference: ExternalTaskRef,
    applied: AppliedRemoteUpdate,
    supported: Vec<ExternalSyncField>,
    unsupported: Vec<ExternalSyncField>,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), SyncClientError> {
    let updated_ref = applied.reference;
    let provider_revision = applied.provider_revision;
    let refs = replace_synced_ref(
        item,
        &reference,
        &updated_ref,
        &supported,
        provider_revision.as_deref(),
    );
    let remote = updated_remote_task(
        item,
        &reference,
        updated_ref.clone(),
        &supported,
        provider_revision.as_deref(),
    );
    if let Err(error) = board
        .update_item(
            item,
            TaskBoardItemPatch {
                external_refs: Some(refs),
                ..TaskBoardItemPatch::default()
            },
        )
        .await
    {
        operations.push(push_operation(
            client.provider(),
            item,
            updated_ref,
            false,
            false,
            supported.clone(),
            unsupported,
        ));
        persist_push_conflicts(board, item, &remote, &supported)
            .await
            .map_err(SyncClientError::Local)?;
        return Err(SyncClientError::Local(error));
    }
    operations.push(push_operation(
        client.provider(),
        item,
        updated_ref.clone(),
        false,
        true,
        supported.clone(),
        unsupported,
    ));
    let snapshot = board
        .item_snapshot(&item.id)
        .await
        .map_err(SyncClientError::Local)?;
    board
        .supersede_open_sync_conflicts(
            &item.id,
            client.provider(),
            &updated_ref.external_id,
            snapshot.item_revision,
            &supported,
        )
        .await
        .map_err(SyncClientError::Local)?;
    republish_github_board_ready(client.provider());
    Ok(())
}

async fn persist_push_conflicts(
    board: &dyn TaskBoardSyncStore,
    expected_item: &TaskBoardItem,
    remote: &ExternalTask,
    fields: &[ExternalSyncField],
) -> Result<(), CliError> {
    let snapshot = board.item_snapshot(&expected_item.id).await?;
    let conflicts = build_sync_conflicts(&snapshot.item, remote, fields, snapshot.item_revision);
    board
        .replace_open_sync_conflicts(
            &snapshot.item.id,
            remote.reference.provider,
            &remote.reference.external_id,
            snapshot.item_revision,
            &conflicts,
        )
        .await
}

fn updated_remote_task(
    item: &TaskBoardItem,
    current_ref: &ExternalTaskRef,
    updated_ref: ExternalTaskRef,
    changed_fields: &[ExternalSyncField],
    provider_revision: Option<&str>,
) -> ExternalTask {
    let state = matching_ref(item, current_ref, item.project_id.as_deref())
        .and_then(|reference| reference.sync_state.as_ref());
    ExternalTask {
        reference: updated_ref,
        title: pushed_value(
            changed_fields,
            ExternalSyncField::Title,
            &item.title,
            state.and_then(|state| state.title.as_deref()),
        ),
        body: pushed_value(
            changed_fields,
            ExternalSyncField::Body,
            &item.body,
            state.and_then(|state| state.body.as_deref()),
        ),
        status: if changed_fields.contains(&ExternalSyncField::Status) {
            canonical_external_status(item.status)
        } else {
            state.and_then(|state| state.status).map_or_else(
                || canonical_external_status(item.status),
                canonical_external_status,
            )
        },
        project_id: if changed_fields.contains(&ExternalSyncField::Project) {
            item.project_id.clone()
        } else {
            state
                .and_then(|state| state.project_id.clone())
                .or_else(|| item.project_id.clone())
        },
        updated_at: provider_revision.map(ToOwned::to_owned),
    }
}

fn pushed_value(
    changed_fields: &[ExternalSyncField],
    field: ExternalSyncField,
    local: &str,
    previous: Option<&str>,
) -> String {
    if changed_fields.contains(&field) {
        local.to_owned()
    } else {
        previous.map_or_else(|| local.to_owned(), ToOwned::to_owned)
    }
}

fn push_operation(
    provider: ExternalProvider,
    item: &TaskBoardItem,
    reference: ExternalTaskRef,
    dry_run: bool,
    applied: bool,
    changed_fields: Vec<ExternalSyncField>,
    unsupported_fields: Vec<ExternalSyncField>,
) -> ExternalSyncOperation {
    operation(OperationDraft {
        provider,
        action: ExternalSyncAction::Push,
        board_item_id: Some(item.id.clone()),
        reference,
        dry_run,
        applied,
        changed_fields,
        unsupported_fields,
    })
}

fn republish_github_board_ready(provider: ExternalProvider) {
    if provider == ExternalProvider::GitHub {
        republish_current_data_change("task_board.github.local_sync_ready");
    }
}

fn remote_precondition(item: &TaskBoardItem, reference: &ExternalTaskRef) -> Option<String> {
    matching_ref(item, reference, item.project_id.as_deref())
        .and_then(|reference| reference.sync_state.as_ref())
        .and_then(|state| state.updated_at.clone())
}

#[cfg(test)]
mod tests;
