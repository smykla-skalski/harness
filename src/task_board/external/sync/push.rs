use crate::errors::CliError;
use crate::github_api::republish_current_data_change;
use crate::task_board::external::ExternalProviderScopeAttempt;
use crate::task_board::external::targeting::provider_project_maps_to_board;
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::types::{TaskBoardItem, TaskBoardStatus};

use super::conflicts::build_sync_conflicts;
use super::lookup::{OperationDraft, operation, provider_ref};
use super::merge::{
    has_reported_conflict, local_update_fields, matching_ref, push_create_fields,
    replace_synced_ref, split_supported_fields, synced_ref_from_item,
};
use super::{
    ExternalCreateOutcome, ExternalProvider, ExternalSyncAction, ExternalSyncClient,
    ExternalSyncField, ExternalSyncOperation, ExternalSyncOptions, ExternalTask, ExternalTaskRef,
    ExternalTaskUpdate, ExternalUpdateOutcome, SyncClientError, TaskBoardSyncStore,
    canonical_external_status,
};

pub(super) async fn push_board_tasks(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), SyncClientError> {
    let items = board
        .list_items(options.status)
        .await
        .map_err(SyncClientError::Local)?;
    let scope_id = client.scope_id();
    for item in &items {
        push_board_item(board, options, client, attempt, item, &scope_id, operations).await?;
    }
    Ok(())
}

async fn push_board_item(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    item: &TaskBoardItem,
    scope_id: &str,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), SyncClientError> {
    if !super::client_owns_item(client, item, scope_id)
        || has_reported_conflict(operations, client.provider(), &item.id)
    {
        return Ok(());
    }
    if let Some(reference) = provider_ref(item, client.provider()) {
        update_linked_remote(board, options, client, attempt, item, reference, operations).await
    } else {
        create_remote_item(board, options, client, attempt, item, operations).await
    }
}

async fn create_remote_item(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    item: &TaskBoardItem,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), SyncClientError> {
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
        return Ok(());
    }
    super::scope::renew_scope_attempt(board, attempt).await?;
    let ExternalCreateOutcome {
        reference,
        provider_revision,
        provider_project_id,
    } = client
        .push_task_with_outcome(item)
        .await
        .map_err(SyncClientError::Provider)?;
    let mut refs = item.external_refs.clone();
    refs.push(synced_ref_from_item(
        reference.clone(),
        item,
        provider_project_id.as_deref(),
        provider_revision.as_deref(),
    ));
    let project_id =
        provider_project_patch(item, client.provider(), provider_project_id.as_deref());
    let execution_repository =
        provider_repository_patch(item, client.provider(), provider_project_id.as_deref());
    let linked = match board
        .update_item(
            item,
            TaskBoardItemPatch {
                project_id,
                execution_repository,
                external_refs: Some(refs),
                ..TaskBoardItemPatch::default()
            },
        )
        .await
    {
        Ok(linked) => linked,
        Err(error) => {
            let remote = created_remote_task(
                item,
                reference.clone(),
                provider_project_id,
                provider_revision,
            );
            operations.push(push_operation(
                client.provider(),
                item,
                reference,
                false,
                false,
                changed_fields.clone(),
                Vec::new(),
            ));
            persist_push_conflicts(board, item, &remote, &changed_fields)
                .await
                .map_err(SyncClientError::Local)?;
            return Err(SyncClientError::Local(error));
        }
    };
    republish_github_board_ready(client.provider());
    operations.push(push_operation(
        client.provider(),
        item,
        reference.clone(),
        false,
        true,
        changed_fields,
        Vec::new(),
    ));
    if canonical_external_status(item.status) == TaskBoardStatus::Done {
        update_linked_remote(
            board, options, client, attempt, &linked, reference, operations,
        )
        .await?;
    }
    Ok(())
}

fn provider_project_patch(
    item: &TaskBoardItem,
    provider: ExternalProvider,
    provider_project_id: Option<&str>,
) -> OptionalFieldPatch<String> {
    if !provider_project_maps_to_board(provider)
        || item.project_id.as_deref() == provider_project_id
    {
        return OptionalFieldPatch::Unchanged;
    }
    provider_project_id
        .map(ToOwned::to_owned)
        .map_or(OptionalFieldPatch::Clear, OptionalFieldPatch::Set)
}

fn provider_repository_patch(
    item: &TaskBoardItem,
    provider: ExternalProvider,
    provider_project_id: Option<&str>,
) -> OptionalFieldPatch<String> {
    if provider != ExternalProvider::GitHub {
        return OptionalFieldPatch::Unchanged;
    }
    let Some(provider_project_id) = provider_project_id else {
        return OptionalFieldPatch::Unchanged;
    };
    if item.execution_repository.as_deref() == Some(provider_project_id) {
        return OptionalFieldPatch::Unchanged;
    }
    OptionalFieldPatch::Set(provider_project_id.to_owned())
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
    let clears_conflicts = unsupported.is_empty();
    operations.push(push_operation(
        client.provider(),
        item,
        updated_ref.clone(),
        false,
        true,
        supported,
        unsupported,
    ));
    if clears_conflicts {
        let snapshot = board
            .item_snapshot(&item.id)
            .await
            .map_err(SyncClientError::Local)?;
        board
            .replace_open_sync_conflicts(
                &item.id,
                client.provider(),
                &updated_ref.external_id,
                snapshot.item_revision,
                &[],
            )
            .await
            .map_err(SyncClientError::Local)?;
    }
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

fn created_remote_task(
    item: &TaskBoardItem,
    reference: ExternalTaskRef,
    provider_project_id: Option<String>,
    provider_revision: Option<String>,
) -> ExternalTask {
    ExternalTask {
        reference,
        title: item.title.clone(),
        body: item.body.clone(),
        status: TaskBoardStatus::Backlog,
        project_id: provider_project_id,
        updated_at: provider_revision,
    }
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
