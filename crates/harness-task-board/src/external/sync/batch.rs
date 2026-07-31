use crate::external::TaskBoardExternalCreateIntent;
use crate::external::{
    ExternalProvider, ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
    ExternalProviderScopeAvailability, ExternalProviderScopeIdentity, ExternalSyncBatch,
    ExternalSyncClient, ExternalSyncScopeOutcome,
};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_workspace::workspace::utc_now;

use super::create_recovery::{
    ExternalCreateRecoveryPlan, ExternalCreateScopeRecovery, recover_scope_intents,
};
use super::lookup::provider_is_allowed;
use super::{ExternalSyncOperation, ExternalSyncOptions, SyncClientError, TaskBoardSyncStore};

mod client;
mod concurrent;
use client::{SyncClientResult, sync_client};

/// Pull and/or push task-board items through configured provider clients.
///
/// # Errors
/// Returns `CliError` when every attempted provider scope fails or local persistence fails.
pub async fn sync_external_tasks(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    clients: &[Box<dyn ExternalSyncClient>],
) -> Result<Vec<ExternalSyncOperation>, CliError> {
    sync_external_tasks_scoped(board, options, clients)
        .await
        .and_then(ExternalSyncBatch::into_operations)
}

/// # Errors
/// Returns `CliError` when every attempted provider scope fails or local persistence fails.
pub async fn sync_external_tasks_scoped(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    clients: &[Box<dyn ExternalSyncClient>],
) -> Result<ExternalSyncBatch, CliError> {
    sync_external_tasks_scoped_with_recovery(
        board,
        options,
        clients,
        ExternalCreateRecoveryPlan::default(),
    )
    .await
}

/// # Errors
/// Returns `CliError` when every attempted provider scope fails or local persistence fails.
pub async fn sync_external_tasks_scoped_with_recovery(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    clients: &[Box<dyn ExternalSyncClient>],
    mut recovery: ExternalCreateRecoveryPlan,
) -> Result<ExternalSyncBatch, CliError> {
    let mut batch = BatchAccumulator {
        operations: recovery.take_operations(),
        external_create_follow_ups: recovery.take_follow_ups(),
        ..BatchAccumulator::default()
    };
    let work = clients
        .iter()
        .enumerate()
        .filter(|(_, client)| provider_is_allowed(client.provider(), options.provider))
        .map(|(index, client)| {
            let scope = ExternalProviderScopeIdentity::for_client(client.as_ref());
            concurrent::ScopeWork {
                index,
                client: client.as_ref(),
                recovery: recovery.take_scope(scope.provider(), scope.scope_id()),
            }
        })
        .collect();
    batch = concurrent::sync_scopes(board, options, work, batch).await?;
    if batch.terminal_error.is_none() && recovery.has_recovery() {
        let blocked = recovery.into_blocked(
            CliErrorKind::workflow_io(
                "provider create recovery has no configured client for its persisted scope",
            )
            .into(),
        );
        batch.scope_outcomes.extend(blocked.scope_outcomes);
        batch.terminal_error = blocked.terminal_error;
    }
    Ok(ExternalSyncBatch {
        operations: batch.operations,
        external_create_follow_ups: batch.external_create_follow_ups,
        scope_outcomes: batch.scope_outcomes,
        ambiguous_references: batch.ambiguous_references,
        first_provider_failure: batch.first_provider_failure,
        terminal_error: batch.terminal_error,
    })
}

#[derive(Default)]
pub(super) struct BatchAccumulator {
    pub(super) ambiguous_references: Vec<String>,
    pub(super) operations: Vec<ExternalSyncOperation>,
    pub(super) external_create_follow_ups: Vec<TaskBoardExternalCreateIntent>,
    pub(super) scope_outcomes: Vec<ExternalSyncScopeOutcome>,
    pub(super) first_provider_failure: Option<CliError>,
    pub(super) terminal_error: Option<CliError>,
}

pub(super) async fn sync_scope(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    recovery: &ExternalCreateScopeRecovery,
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
    sync_admitted_scope(
        board,
        options,
        client,
        &scope,
        attempt.as_ref(),
        recovery,
        batch,
    )
    .await
}

async fn sync_admitted_scope(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    scope: &ExternalProviderScopeIdentity,
    attempt: Option<&ExternalProviderScopeAttempt>,
    recovery: &ExternalCreateScopeRecovery,
    batch: &mut BatchAccumulator,
) -> Result<(), CliError> {
    let provider = scope.provider();
    let scope_id = scope.scope_id().to_owned();
    let sync_result = run_scope_work(
        board,
        options,
        client,
        attempt,
        &recovery.intents,
        &mut batch.operations,
        &mut batch.external_create_follow_ups,
    )
    .await?;
    finish_scope_work(
        board,
        attempt,
        provider,
        scope_id,
        recovery.touched,
        sync_result,
        batch,
    )
    .await
}

async fn run_scope_work(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    attempt: Option<&ExternalProviderScopeAttempt>,
    recovery_intents: &[TaskBoardExternalCreateIntent],
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<Result<SyncClientResult, SyncClientError>, CliError> {
    if recovery_intents.is_empty() {
        return Ok(sync_client(board, options, client, attempt, operations, follow_ups).await);
    }
    let Some(attempt) = attempt else {
        return Err(CliErrorKind::workflow_io(
            "provider create recovery requires a persisted scope attempt",
        )
        .into());
    };
    if let Err(error) = recover_scope_intents(
        board,
        client,
        attempt,
        recovery_intents,
        operations,
        follow_ups,
    )
    .await
    {
        return Ok(Err(error));
    }
    Ok(sync_client(
        board,
        options,
        client,
        Some(attempt),
        operations,
        follow_ups,
    )
    .await)
}

async fn finish_scope_work(
    board: &dyn TaskBoardSyncStore,
    attempt: Option<&ExternalProviderScopeAttempt>,
    provider: ExternalProvider,
    scope_id: String,
    recovery_touched: bool,
    sync_result: Result<SyncClientResult, SyncClientError>,
    batch: &mut BatchAccumulator,
) -> Result<(), CliError> {
    match sync_result {
        Ok(result) => {
            batch
                .ambiguous_references
                .extend(result.ambiguous_references);
            let base_revision = (!recovery_touched && !result.durable_create)
                .then_some(result.base_revision)
                .flatten();
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
    if board.coordinator_cancelled() {
        record_coordinator_cancellation(board, attempt, provider, scope_id, error, batch).await;
        return;
    }
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

async fn record_coordinator_cancellation(
    board: &dyn TaskBoardSyncStore,
    attempt: Option<&ExternalProviderScopeAttempt>,
    provider: ExternalProvider,
    scope_id: String,
    error: CliError,
    batch: &mut BatchAccumulator,
) {
    let terminal_error = if let Some(attempt) = attempt {
        match board
            .release_provider_scope_attempt(attempt, &utc_now())
            .await
        {
            Ok(()) => error,
            Err(release_error) => combined_neutral_release_failure(error, &release_error),
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

fn combined_neutral_release_failure(
    cancellation_error: CliError,
    release_error: &CliError,
) -> CliError {
    let release_details = format!(
        "neutral provider scope release also failed with {}",
        error_with_details(release_error)
    );
    let details = match cancellation_error.details() {
        Some(details) => format!("{details}; {release_details}"),
        None => release_details,
    };
    cancellation_error.with_details(details)
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
