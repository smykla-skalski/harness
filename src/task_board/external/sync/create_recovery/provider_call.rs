use crate::errors::CliErrorKind;
use crate::task_board::external::{
    ExternalCreateProbe, ExternalCreateRecoveryClient, ExternalSyncOperation,
};
use crate::task_board::{
    TaskBoardExternalCreateIntent, TaskBoardExternalCreateIntentState, TaskBoardItem,
};

use super::super::{SyncClientError, TaskBoardSyncStore};
use super::execute::{finish_reloaded_intent, persist_exact_task, request_from_intent};
use super::lease::ScopeCreateLease;
use super::reload_intent;

pub(super) async fn create_started(
    board: &dyn TaskBoardSyncStore,
    capability: &dyn ExternalCreateRecoveryClient,
    lease: &ScopeCreateLease<'_>,
    intent: &TaskBoardExternalCreateIntent,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<Option<TaskBoardItem>, SyncClientError> {
    let current = reload_current_intent(board, lease, intent).await?;
    if !matches!(current.state, TaskBoardExternalCreateIntentState::InFlight) {
        return finish_reloaded_intent(board, &current, operations, follow_ups)
            .await
            .map_err(SyncClientError::Local);
    }
    lease
        .renew_before_provider_call()
        .await
        .map_err(SyncClientError::Local)?;
    lease.begin_provider_call();
    let task = capability
        .create_started(&request_from_intent(&current), lease)
        .await
        .map_err(|error| lease.classify_provider_call(error).into_sync_client_error())?;
    persist_exact_task(board, &current, task, operations, follow_ups)
        .await
        .map_err(SyncClientError::Local)
}

pub(super) async fn recover_existing(
    board: &dyn TaskBoardSyncStore,
    capability: &dyn ExternalCreateRecoveryClient,
    lease: &ScopeCreateLease<'_>,
    intent: &TaskBoardExternalCreateIntent,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<Option<TaskBoardItem>, SyncClientError> {
    let current = reload_current_intent(board, lease, intent).await?;
    if !matches!(current.state, TaskBoardExternalCreateIntentState::InFlight) {
        return finish_reloaded_intent(board, &current, operations, follow_ups)
            .await
            .map_err(SyncClientError::Local);
    }
    lease
        .renew_before_provider_call()
        .await
        .map_err(SyncClientError::Local)?;
    lease.begin_provider_call();
    let probe = capability
        .recover_existing(&request_from_intent(&current), lease)
        .await
        .map_err(|error| lease.classify_provider_call(error).into_sync_client_error())?;
    let ExternalCreateProbe::Found(task) = probe else {
        return Err(SyncClientError::Provider(
            CliErrorKind::workflow_io(format!(
                "provider create recovery found no task for '{}'",
                current.item_id
            ))
            .into(),
        ));
    };
    persist_exact_task(board, &current, task, operations, follow_ups)
        .await
        .map_err(SyncClientError::Local)
}

async fn reload_current_intent(
    board: &dyn TaskBoardSyncStore,
    lease: &ScopeCreateLease<'_>,
    intent: &TaskBoardExternalCreateIntent,
) -> Result<TaskBoardExternalCreateIntent, SyncClientError> {
    lease.renew_scope().await.map_err(SyncClientError::Local)?;
    reload_intent(board, intent)
        .await
        .map_err(SyncClientError::Local)
}
