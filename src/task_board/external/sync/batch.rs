use crate::errors::CliError;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
    ExternalProviderScopeAvailability, ExternalProviderScopeIdentity, ExternalSyncBatch,
    ExternalSyncClient, ExternalSyncScopeOutcome,
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
    let scope = ExternalProviderScopeIdentity::for_client(client);
    let provider = scope.provider();
    let scope_id = scope.scope_id().to_owned();
    let attempt = match admit_scope(board, options, &scope).await? {
        ScopeAdmission::Run(attempt) => attempt,
        ScopeAdmission::BackingOff | ScopeAdmission::Fenced => {
            batch
                .scope_outcomes
                .push(ExternalSyncScopeOutcome::backing_off(provider, scope_id));
            return Ok(());
        }
    };
    sync_admitted_scope(board, options, client, &scope, attempt.as_ref(), batch).await
}

async fn sync_admitted_scope(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    scope: &ExternalProviderScopeIdentity,
    attempt: Option<&ExternalProviderScopeAttempt>,
    batch: &mut BatchAccumulator,
) -> Result<(), CliError> {
    let provider = scope.provider();
    let scope_id = scope.scope_id().to_owned();
    match sync_client(board, options, client, attempt, &mut batch.operations).await {
        Ok(base_revision) => {
            if let Some(attempt) = attempt {
                board
                    .complete_provider_scope_success(attempt, base_revision.as_deref(), &utc_now())
                    .await?;
            }
            batch
                .scope_outcomes
                .push(ExternalSyncScopeOutcome::success(provider, scope_id));
        }
        Err(SyncClientError::Provider(error)) => {
            if let Some(attempt) = attempt {
                board
                    .complete_provider_scope_failure(attempt, &utc_now())
                    .await?;
            }
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

enum ScopeAdmission {
    Run(Option<ExternalProviderScopeAttempt>),
    BackingOff,
    Fenced,
}

async fn admit_scope(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    scope: &ExternalProviderScopeIdentity,
) -> Result<ScopeAdmission, CliError> {
    let now = utc_now();
    if options.dry_run {
        return board
            .provider_scope_state(scope.provider(), scope.scope_id())
            .await?
            .availability_at(&now)
            .map(|availability| match availability {
                ExternalProviderScopeAvailability::Ready => ScopeAdmission::Run(None),
                ExternalProviderScopeAvailability::BackingOff => ScopeAdmission::BackingOff,
                ExternalProviderScopeAvailability::Fenced => ScopeAdmission::Fenced,
            });
    }
    board
        .begin_provider_scope_attempt(scope.provider(), scope.scope_id(), &now)
        .await
        .map(|decision| match decision {
            ExternalProviderScopeAttemptDecision::Started(attempt) => {
                ScopeAdmission::Run(Some(attempt))
            }
            ExternalProviderScopeAttemptDecision::BackingOff => ScopeAdmission::BackingOff,
            ExternalProviderScopeAttemptDecision::Fenced => ScopeAdmission::Fenced,
        })
}

async fn sync_client(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<Option<String>, SyncClientError> {
    let base_revision = pull_client_tasks(board, options, client, attempt, operations).await?;
    push_client_tasks(board, options, client, attempt, operations).await?;
    Ok(base_revision)
}

async fn pull_client_tasks(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<Option<String>, SyncClientError> {
    if !direction_allows_pull(options.direction) || !client.allows_pull() {
        return Ok(None);
    }
    super::scope::renew_scope_attempt(board, attempt).await?;
    let tasks = client
        .pull_tasks()
        .await
        .map_err(SyncClientError::Provider)?;
    super::scope::renew_scope_attempt(board, attempt).await?;
    let base_revision = tasks
        .iter()
        .filter_map(|task| task.updated_at.as_ref())
        .max()
        .cloned();
    pull_provider_tasks(board, options, client, tasks, operations)
        .await
        .map_err(SyncClientError::Local)?;
    Ok(base_revision)
}

async fn push_client_tasks(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), SyncClientError> {
    if direction_allows_push(options.direction) && client.allows_push() {
        push_board_tasks(board, options, client, attempt, operations).await?;
        delete_remote_tombstones(board, options, client, attempt, operations).await?;
    }
    Ok(())
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
