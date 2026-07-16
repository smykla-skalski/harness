use crate::errors::CliError;
use crate::task_board::external::{
    ExternalSyncBatch, ExternalSyncClient, ExternalSyncScopeOutcome,
};
use crate::workspace::utc_now;

use super::delete::delete_remote_tombstones;
use super::lookup::provider_is_allowed;
use super::{
    ExternalSyncDirection, ExternalSyncOperation, ExternalSyncOptions, SyncClientError,
    TaskBoardSyncStore, pull_provider_tasks, push_board_tasks,
};

/// Pull and/or push task-board items through configured provider clients.
///
/// # Errors
/// Returns `CliError` when every attempted provider scope fails or local persistence fails.
pub(crate) async fn sync_external_tasks(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    clients: &[Box<dyn ExternalSyncClient>],
) -> Result<Vec<ExternalSyncOperation>, CliError> {
    sync_external_tasks_scoped(board, options, clients)
        .await
        .and_then(ExternalSyncBatch::into_operations)
}

pub(crate) async fn sync_external_tasks_scoped(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    clients: &[Box<dyn ExternalSyncClient>],
) -> Result<ExternalSyncBatch, CliError> {
    let mut batch = BatchAccumulator::default();
    for client in clients {
        if provider_is_allowed(client.provider(), options.provider) {
            sync_scope(board, options, client.as_ref(), &mut batch).await?;
        }
    }
    Ok(ExternalSyncBatch {
        operations: batch.operations,
        scope_outcomes: batch.scope_outcomes,
        first_provider_failure: batch.first_provider_failure,
    })
}

#[derive(Default)]
struct BatchAccumulator {
    operations: Vec<ExternalSyncOperation>,
    scope_outcomes: Vec<ExternalSyncScopeOutcome>,
    first_provider_failure: Option<CliError>,
}

async fn sync_scope(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    batch: &mut BatchAccumulator,
) -> Result<(), CliError> {
    let provider = client.provider();
    let scope_id = client.scope_id();
    let scope_state = board.provider_scope_state(provider, &scope_id).await?;
    if scope_state.is_backing_off_at(&utc_now())? {
        batch
            .scope_outcomes
            .push(ExternalSyncScopeOutcome::backing_off(provider, scope_id));
        return Ok(());
    }
    match sync_client(board, options, client, &mut batch.operations).await {
        Ok(base_revision) => {
            board
                .record_provider_scope_success(provider, &scope_id, base_revision.as_deref())
                .await?;
            batch
                .scope_outcomes
                .push(ExternalSyncScopeOutcome::success(provider, scope_id));
        }
        Err(SyncClientError::Provider(error)) => {
            board
                .record_provider_scope_failure(provider, &scope_id)
                .await?;
            batch
                .scope_outcomes
                .push(ExternalSyncScopeOutcome::failed(provider, scope_id, &error));
            if batch.first_provider_failure.is_none() {
                batch.first_provider_failure = Some(error);
            }
        }
        Err(SyncClientError::Local(error)) => return Err(error),
    }
    Ok(())
}

async fn sync_client(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<Option<String>, SyncClientError> {
    let mut base_revision = None;
    if direction_allows_pull(options.direction) && client.allows_pull() {
        let tasks = client
            .pull_tasks()
            .await
            .map_err(SyncClientError::Provider)?;
        base_revision = tasks
            .iter()
            .filter_map(|task| task.updated_at.as_ref())
            .max()
            .cloned();
        pull_provider_tasks(board, options, client, tasks, operations)
            .await
            .map_err(SyncClientError::Local)?;
    }
    if direction_allows_push(options.direction) && client.allows_push() {
        push_board_tasks(board, options, client, operations).await?;
        delete_remote_tombstones(board, options, client, operations).await?;
    }
    Ok(base_revision)
}

fn direction_allows_pull(direction: ExternalSyncDirection) -> bool {
    matches!(
        direction,
        ExternalSyncDirection::Pull | ExternalSyncDirection::Both
    )
}

fn direction_allows_push(direction: ExternalSyncDirection) -> bool {
    matches!(
        direction,
        ExternalSyncDirection::Push | ExternalSyncDirection::Both
    )
}
