use crate::errors::CliError;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, TaskBoardSyncCoordinatorFenceDecision,
};
use crate::workspace::utc_now;

use super::TaskBoardSyncStore;

pub(super) enum SyncClientError {
    Provider(CliError),
    Local(CliError),
}

pub(super) async fn renew_scope_attempt(
    board: &dyn TaskBoardSyncStore,
    attempt: Option<&ExternalProviderScopeAttempt>,
) -> Result<(), SyncClientError> {
    renew_before_provider_call(board, attempt)
        .await
        .map_err(SyncClientError::Local)
}

pub(super) async fn renew_before_provider_call(
    board: &dyn TaskBoardSyncStore,
    attempt: Option<&ExternalProviderScopeAttempt>,
) -> Result<(), CliError> {
    if let Some(attempt) = attempt {
        board
            .renew_provider_scope_attempt(attempt, &utc_now())
            .await?;
    }
    match board.check_coordinator_fence().await? {
        TaskBoardSyncCoordinatorFenceDecision::Current => Ok(()),
        TaskBoardSyncCoordinatorFenceDecision::Cancelled(error) => Err(error),
    }
}
