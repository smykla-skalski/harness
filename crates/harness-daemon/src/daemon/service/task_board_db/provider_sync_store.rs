use async_trait::async_trait;

use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::task_board::external::{
    ExternalCreateOutcome, ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
    ExternalProviderScopeState, TaskBoardSyncItemSnapshot,
};
use crate::task_board::store::{TaskBoardItemPatch, apply_patch};
use crate::task_board::{
    ExternalProvider, ExternalRef, ExternalSyncField, ProviderExclusionAuditContext,
    ProviderExclusionRestoreOutcome, TaskBoardExternalCreateBegin,
    TaskBoardExternalCreateFinalizeResult, TaskBoardExternalCreateIntent,
    TaskBoardExternalCreateStore, TaskBoardItem, TaskBoardStatus, TaskBoardSyncConflict,
    TaskBoardSyncStore,
};
use harness_kernel::errors::{CliError, CliErrorKind};

#[async_trait]
impl TaskBoardExternalCreateStore for AsyncDaemonDbHandle {
    async fn begin_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        scope_id: &str,
        provider_target: &str,
    ) -> Result<TaskBoardExternalCreateBegin, CliError> {
        self.0
            .begin_task_board_external_create_intent(item_id, provider, scope_id, provider_target)
            .await
    }

    async fn record_external_create_outcome(
        &self,
        intent: &TaskBoardExternalCreateIntent,
        outcome: &ExternalCreateOutcome,
        provider_baseline: &ExternalRef,
    ) -> Result<TaskBoardExternalCreateIntent, CliError> {
        self.0
            .record_task_board_external_create_outcome(intent, outcome, provider_baseline)
            .await
    }

    async fn finalize_external_create_intent(
        &self,
        intent: &TaskBoardExternalCreateIntent,
    ) -> Result<TaskBoardExternalCreateFinalizeResult, CliError> {
        self.0
            .finalize_task_board_external_create_intent(intent)
            .await
    }

    async fn list_created_external_create_intents(
        &self,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        self.0
            .list_created_task_board_external_create_intents()
            .await
    }

    async fn list_in_flight_external_create_intents(
        &self,
        provider: ExternalProvider,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        self.0
            .list_in_flight_task_board_external_create_intents(provider)
            .await
    }

    async fn external_create_intent_by_create_key(
        &self,
        provider: ExternalProvider,
        create_key: &str,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        self.0
            .task_board_external_create_intent_by_create_key(provider, create_key)
            .await
    }

    async fn list_pending_external_create_follow_ups(
        &self,
        provider: Option<ExternalProvider>,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        self.0
            .list_pending_task_board_external_create_follow_ups(provider)
            .await
    }
}

#[async_trait]
impl TaskBoardSyncStore for AsyncDaemonDbHandle {
    async fn list_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        self.0.list_task_board_items(status).await
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        self.0.list_task_board_items_including_deleted().await
    }

    async fn list_item_snapshots_including_deleted(
        &self,
    ) -> Result<Vec<TaskBoardSyncItemSnapshot>, CliError> {
        Ok(self
            .0
            .list_task_board_item_snapshots_including_deleted()
            .await?
            .into_iter()
            .map(|snapshot| TaskBoardSyncItemSnapshot::new(snapshot.item, snapshot.item_revision))
            .collect())
    }

    async fn create_item(&self, item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        Box::pin(self.0.create_task_board_item_with_provider_triage(item))
            .await
            .map(|mutation| mutation.item)
    }

    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        let item_id = expected_item.id.clone();
        let mutation = self
            .0
            .update_task_board_item_with_provider_triage(&item_id, |item| {
                if item != expected_item {
                    return Err(CliErrorKind::concurrent_modification(format!(
                        "task-board item '{item_id}' changed during external sync"
                    ))
                    .into());
                }
                apply_patch(item, patch);
                Ok(true)
            })
            .await?;
        Ok(mutation.map_or_else(|| expected_item.clone(), |mutation| mutation.item))
    }

    async fn item_snapshot(&self, item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError> {
        self.0
            .task_board_item_snapshot(item_id)
            .await
            .map(|snapshot| TaskBoardSyncItemSnapshot::new(snapshot.item, snapshot.item_revision))
    }

    async fn hide_for_provider_exclusion(
        &self,
        item_id: &str,
        expected_revision: i64,
        patch: TaskBoardItemPatch,
        context: ProviderExclusionAuditContext,
        conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<Option<TaskBoardItem>, CliError> {
        super::provider_sync_exclusion::hide_for_provider_exclusion(
            self,
            item_id,
            expected_revision,
            patch,
            &context,
            conflicts,
        )
        .await
    }

    async fn restore_from_provider_exclusion(
        &self,
        expected: TaskBoardSyncItemSnapshot,
        patch: TaskBoardItemPatch,
        context: ProviderExclusionAuditContext,
        conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<ProviderExclusionRestoreOutcome, CliError> {
        Box::pin(
            super::provider_sync_exclusion::restore_from_provider_exclusion(
                self, expected, patch, &context, conflicts,
            ),
        )
        .await
    }

    async fn provider_scope_state(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        self.0
            .task_board_provider_scope_state(provider, scope_id)
            .await
    }

    async fn begin_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        self.0
            .begin_task_board_provider_scope_attempt(provider, scope_id, now)
            .await
    }

    async fn renew_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        now: &str,
    ) -> Result<(), CliError> {
        self.0
            .renew_task_board_provider_scope_attempt(attempt, now)
            .await
    }

    async fn release_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        released_at: &str,
    ) -> Result<(), CliError> {
        self.0
            .release_task_board_provider_scope_attempt(attempt, released_at)
            .await
    }

    async fn complete_provider_scope_success(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        base_revision: Option<&str>,
        completed_at: &str,
    ) -> Result<(), CliError> {
        self.0
            .complete_task_board_provider_scope_success(attempt, base_revision, completed_at)
            .await
    }

    async fn complete_provider_scope_failure(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        self.0
            .complete_task_board_provider_scope_failure(attempt, completed_at)
            .await
    }

    async fn replace_open_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        self.0
            .replace_open_task_board_sync_conflicts(
                item_id,
                provider,
                external_ref,
                item_revision,
                conflicts,
            )
            .await
    }

    async fn supersede_open_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        resolved_fields: &[ExternalSyncField],
    ) -> Result<(), CliError> {
        self.0
            .supersede_open_task_board_sync_conflicts(
                item_id,
                provider,
                external_ref,
                item_revision,
                resolved_fields,
            )
            .await
    }
}

#[cfg(test)]
#[path = "provider_sync_parent_tests.rs"]
mod parent_tests;

#[cfg(test)]
mod tests;
