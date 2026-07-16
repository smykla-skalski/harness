use crate::errors::CliError;
use crate::task_board::external::{
    ExternalProvider, ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
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
            if batch.terminal_error.is_some() {
                break;
            }
        }
    }
    Ok(ExternalSyncBatch {
        operations: batch.operations,
        scope_outcomes: batch.scope_outcomes,
        first_provider_failure: batch.first_provider_failure,
        terminal_error: batch.terminal_error,
    })
}

#[derive(Default)]
struct BatchAccumulator {
    operations: Vec<ExternalSyncOperation>,
    scope_outcomes: Vec<ExternalSyncScopeOutcome>,
    first_provider_failure: Option<CliError>,
    terminal_error: Option<CliError>,
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
            record_scope_success(
                board,
                attempt,
                provider,
                scope_id,
                base_revision.as_deref(),
                batch,
            )
            .await?;
        }
        Err(SyncClientError::Provider(error)) => {
            record_provider_failure(board, attempt, provider, scope_id, error, batch).await?;
        }
        Err(SyncClientError::Local(error)) => {
            record_terminal_local_failure(board, attempt, provider, scope_id, error, batch).await;
        }
    }
    Ok(())
}

async fn record_scope_success(
    board: &dyn TaskBoardSyncStore,
    attempt: Option<&ExternalProviderScopeAttempt>,
    provider: ExternalProvider,
    scope_id: String,
    base_revision: Option<&str>,
    batch: &mut BatchAccumulator,
) -> Result<(), CliError> {
    if let Some(attempt) = attempt {
        board
            .complete_provider_scope_success(attempt, base_revision, &utc_now())
            .await?;
    }
    batch
        .scope_outcomes
        .push(ExternalSyncScopeOutcome::success(provider, scope_id));
    Ok(())
}

async fn record_provider_failure(
    board: &dyn TaskBoardSyncStore,
    attempt: Option<&ExternalProviderScopeAttempt>,
    provider: ExternalProvider,
    scope_id: String,
    error: CliError,
    batch: &mut BatchAccumulator,
) -> Result<(), CliError> {
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
    Ok(())
}

async fn record_terminal_local_failure(
    board: &dyn TaskBoardSyncStore,
    attempt: Option<&ExternalProviderScopeAttempt>,
    provider: ExternalProvider,
    scope_id: String,
    error: CliError,
    batch: &mut BatchAccumulator,
) {
    let terminal_error = if let Some(attempt) = attempt {
        match board
            .complete_provider_scope_failure(attempt, &utc_now())
            .await
        {
            Ok(_) => error,
            Err(finalization_error) => combined_local_failure(error, &finalization_error),
        }
    } else {
        error
    };
    batch.scope_outcomes.push(ExternalSyncScopeOutcome::failed(
        provider,
        scope_id,
        &terminal_error,
    ));
    batch.terminal_error = Some(terminal_error);
}

fn combined_local_failure(local_error: CliError, finalization_error: &CliError) -> CliError {
    let finalization_details = format!(
        "provider scope failure finalization also failed with {}",
        error_with_details(finalization_error)
    );
    let details = match local_error.details() {
        Some(details) => format!("{details}; {finalization_details}"),
        None => finalization_details,
    };
    local_error.with_details(details)
}

fn error_with_details(error: &CliError) -> String {
    error.details().map_or_else(
        || error.to_string(),
        |details| format!("{error}; {details}"),
    )
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
