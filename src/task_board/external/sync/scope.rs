use crate::errors::CliError;
use crate::task_board::external::ExternalProviderScopeAttempt;
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
    if let Some(attempt) = attempt {
        board
            .renew_provider_scope_attempt(attempt, &utc_now())
            .await
            .map_err(SyncClientError::Local)?;
    }
    Ok(())
}
