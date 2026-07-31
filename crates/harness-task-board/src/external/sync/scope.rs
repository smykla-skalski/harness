use std::future::Future;
use std::time::Duration;

use crate::external::{ExternalProviderScopeAttempt, TaskBoardSyncCoordinatorFenceDecision};
use harness_kernel::errors::CliError;
use harness_workspace::workspace::utc_now;
use tokio::time::{MissedTickBehavior, interval};

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

pub(super) async fn await_provider_call<T, E>(
    board: &dyn TaskBoardSyncStore,
    call: impl Future<Output = Result<T, E>>,
) -> Result<Result<T, E>, CliError> {
    tokio::pin!(call);
    let mut cancellation_poll = interval(Duration::from_millis(25));
    cancellation_poll.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            result = &mut call => return Ok(result),
            _ = cancellation_poll.tick() => {
                match board.check_coordinator_fence().await? {
                    TaskBoardSyncCoordinatorFenceDecision::Current => {}
                    TaskBoardSyncCoordinatorFenceDecision::Cancelled(error) => {
                        return Err(error);
                    }
                }
            }
        }
    }
}
