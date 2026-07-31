use crate::external::{
    ExternalProviderScopeAttempt, ExternalSyncClient, TaskBoardExternalCreateIntent,
};

use super::super::delete::delete_remote_tombstones;
use super::super::{
    ExternalSyncDirection, ExternalSyncOperation, ExternalSyncOptions, SyncClientError,
    TaskBoardSyncStore, pull_provider_tasks, push_board_tasks,
};

pub(super) struct SyncClientResult {
    pub(super) base_revision: Option<String>,
    pub(super) durable_create: bool,
    pub(super) ambiguous_references: Vec<String>,
}

struct PullClientResult {
    base_revision: Option<String>,
    recovered_create: bool,
    /// References this scope left alone because more than one board item
    /// claims them. Carried up so the run reports them instead of losing them
    /// with the scope that skipped them.
    ambiguous_references: Vec<String>,
}

pub(super) async fn sync_client(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<SyncClientResult, SyncClientError> {
    let pull = pull_client_tasks(board, options, client, attempt, operations, follow_ups).await?;
    let pushed_create =
        push_client_tasks(board, options, client, attempt, operations, follow_ups).await?;
    Ok(SyncClientResult {
        base_revision: pull.base_revision,
        durable_create: pull.recovered_create || pushed_create,
        ambiguous_references: pull.ambiguous_references,
    })
}

async fn pull_client_tasks(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<PullClientResult, SyncClientError> {
    if !direction_allows_pull(options.direction) || !client.allows_pull() {
        return Ok(PullClientResult {
            base_revision: None,
            recovered_create: false,
            ambiguous_references: Vec::new(),
        });
    }
    super::super::scope::renew_scope_attempt(board, attempt).await?;
    let tasks = super::super::scope::await_provider_call(board, client.pull_tasks())
        .await
        .map_err(SyncClientError::Local)?
        .map_err(SyncClientError::Provider)?;
    super::super::scope::renew_scope_attempt(board, attempt).await?;
    let base_revision = tasks
        .iter()
        .filter_map(|task| task.updated_at.as_ref())
        .max()
        .cloned();
    let mut ambiguous_references = Vec::new();
    let recovered_create = pull_provider_tasks(
        board,
        options,
        client,
        tasks,
        operations,
        follow_ups,
        &mut ambiguous_references,
    )
    .await
    .map_err(SyncClientError::Local)?;
    Ok(PullClientResult {
        base_revision,
        recovered_create,
        ambiguous_references,
    })
}

async fn push_client_tasks(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<bool, SyncClientError> {
    if direction_allows_push(options.direction) && client.allows_push() {
        let created =
            push_board_tasks(board, options, client, attempt, operations, follow_ups).await?;
        delete_remote_tombstones(board, options, client, attempt, operations).await?;
        return Ok(created);
    }
    Ok(false)
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
