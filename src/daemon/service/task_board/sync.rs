use crate::daemon::protocol::{TaskBoardSyncRequest, TaskBoardSyncResponse};
use crate::errors::{CliError, CliErrorKind};
#[cfg(test)]
use crate::task_board::TaskBoardStore;
use crate::task_board::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConfig, ExternalSyncDirection,
    ExternalSyncOperation, ExternalSyncOptions, TaskBoardItem, build_sync_summary,
};

pub(crate) fn sync_options(request: &TaskBoardSyncRequest) -> ExternalSyncOptions {
    ExternalSyncOptions {
        status: request.status,
        provider: request.provider,
        direction: request.direction,
        conflict_policy: request.conflict_policy,
        dry_run: request.dry_run,
    }
}

pub(crate) fn ensure_sync_request_can_run(
    request: &TaskBoardSyncRequest,
    config: &ExternalSyncConfig,
    clients: &[Box<dyn ExternalSyncClient>],
) -> Result<(), CliError> {
    if clients.is_empty() {
        return Ok(());
    }
    if has_available_sync_client(request, clients) {
        return Ok(());
    }
    reject_sync_request(request, config)
}

#[cfg(test)]
pub(super) fn build_sync_response(
    board: &TaskBoardStore,
    request: &TaskBoardSyncRequest,
    config: &ExternalSyncConfig,
    operations: Vec<ExternalSyncOperation>,
) -> Result<TaskBoardSyncResponse, CliError> {
    let items = board.list(request.status)?;
    Ok(build_sync_response_from_items(&items, config, operations))
}

pub(crate) fn build_sync_response_from_items(
    items: &[TaskBoardItem],
    config: &ExternalSyncConfig,
    operations: Vec<ExternalSyncOperation>,
) -> TaskBoardSyncResponse {
    let mut summary = build_sync_summary(items, config);
    summary.operations = operations;
    summary
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(crate) fn log_sync_request(
    request: &TaskBoardSyncRequest,
    config: &ExternalSyncConfig,
    client_count: usize,
) {
    tracing::info!(
        "{}",
        format_sync_request_message(request, config, client_count)
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(crate) fn log_sync_completion(summary: &TaskBoardSyncResponse) {
    tracing::info!("{}", format_sync_completion_message(summary));
}

fn has_available_sync_client(
    request: &TaskBoardSyncRequest,
    clients: &[Box<dyn ExternalSyncClient>],
) -> bool {
    clients
        .iter()
        .any(|client| client_can_run(request, client.as_ref()))
}

fn client_can_run(request: &TaskBoardSyncRequest, client: &dyn ExternalSyncClient) -> bool {
    if request
        .provider
        .is_some_and(|provider| provider != client.provider())
    {
        return false;
    }
    match request.direction {
        ExternalSyncDirection::Pull => client.allows_pull(),
        ExternalSyncDirection::Push => client.allows_push(),
        ExternalSyncDirection::Both => client.allows_pull() || client.allows_push(),
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn reject_sync_request(
    request: &TaskBoardSyncRequest,
    config: &ExternalSyncConfig,
) -> Result<(), CliError> {
    let message = sync_request_unavailable_message(request, config);
    tracing::warn!("task-board sync cannot run: {message}");
    Err(CliErrorKind::workflow_io(message).into())
}

fn sync_request_unavailable_message(
    request: &TaskBoardSyncRequest,
    config: &ExternalSyncConfig,
) -> String {
    if matches!(
        request.direction,
        ExternalSyncDirection::Pull | ExternalSyncDirection::Both
    ) && request
        .provider
        .is_none_or(|provider| provider == ExternalProvider::GitHub)
        && config.token_for(ExternalProvider::GitHub).is_some()
        && config.github_repository().is_none()
        && config.github_inbox_repositories().is_empty()
    {
        return "GitHub pull sync requires a configured repository or inbox repository. \
Set Task Board GitHub owner/repo or add a GitHub inbox repository in Settings."
            .to_string();
    }
    format!(
        "task-board {:?} sync has no configured {:?} provider client",
        request.direction, request.provider
    )
}

fn format_sync_request_message(
    request: &TaskBoardSyncRequest,
    config: &ExternalSyncConfig,
    client_count: usize,
) -> String {
    format!(
        "task-board sync requested: provider={:?} direction={:?} dry_run={} status={:?} client_count={} github_token_configured={} github_repository_configured={} github_inbox_repositories={} todoist_token_configured={}",
        request.provider,
        request.direction,
        request.dry_run,
        request.status,
        client_count,
        config.token_for(ExternalProvider::GitHub).is_some(),
        config.github_repository().is_some(),
        config.github_inbox_repositories().len(),
        config.token_for(ExternalProvider::Todoist).is_some(),
    )
}

fn format_sync_completion_message(summary: &TaskBoardSyncResponse) -> String {
    format!(
        "task-board sync completed: total={} providers={} operations={}",
        summary.total,
        summary.providers.len(),
        summary.operations.len(),
    )
}
