use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;

use crate::errors::CliError;
use crate::task_board::external::{
    ExternalCreateLease, ExternalProviderScopeAttempt, TaskBoardSyncCoordinatorFenceDecision,
};
use crate::workspace::utc_now;

use super::super::{SyncClientError, TaskBoardSyncStore};

pub(super) struct ScopeCreateLease<'a> {
    board: &'a dyn TaskBoardSyncStore,
    attempt: &'a ExternalProviderScopeAttempt,
    local_failure: AtomicBool,
}

pub(super) enum RecoveryCallError {
    Local(CliError),
    Provider(CliError),
}

impl<'a> ScopeCreateLease<'a> {
    pub(super) fn new(
        board: &'a dyn TaskBoardSyncStore,
        attempt: &'a ExternalProviderScopeAttempt,
    ) -> Self {
        Self {
            board,
            attempt,
            local_failure: AtomicBool::new(false),
        }
    }

    pub(super) fn begin_provider_call(&self) {
        self.local_failure.store(false, Ordering::SeqCst);
    }

    pub(super) fn classify_provider_call(&self, error: CliError) -> RecoveryCallError {
        if self.local_failure.swap(false, Ordering::SeqCst) {
            RecoveryCallError::Local(error)
        } else {
            RecoveryCallError::Provider(error)
        }
    }

    pub(super) async fn renew_scope(&self) -> Result<(), CliError> {
        self.board
            .renew_provider_scope_attempt(self.attempt, &utc_now())
            .await
    }

    pub(super) async fn renew_before_provider_call(&self) -> Result<(), CliError> {
        self.renew_scope().await?;
        match self.board.check_coordinator_fence().await? {
            TaskBoardSyncCoordinatorFenceDecision::Current => Ok(()),
            TaskBoardSyncCoordinatorFenceDecision::Cancelled(error) => Err(error),
        }
    }
}

impl RecoveryCallError {
    pub(super) fn into_sync_client_error(self) -> SyncClientError {
        match self {
            Self::Local(error) => SyncClientError::Local(error),
            Self::Provider(error) => SyncClientError::Provider(error),
        }
    }
}

#[async_trait]
impl ExternalCreateLease for ScopeCreateLease<'_> {
    async fn renew(&self) -> Result<(), CliError> {
        let result = self.renew_before_provider_call().await;
        if result.is_err() {
            self.local_failure.store(true, Ordering::SeqCst);
        }
        result
    }
}
