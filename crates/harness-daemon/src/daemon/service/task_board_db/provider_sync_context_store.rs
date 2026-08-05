use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;

use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::task_board::external::{
    ExternalCreateOutcome, ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
    ExternalProviderScopeState, TaskBoardSyncCoordinatorFence,
    TaskBoardSyncCoordinatorFenceDecision, TaskBoardSyncItemSnapshot,
};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{
    ExternalProvider, ExternalRef, ExternalSyncField, ProviderExclusionAuditContext,
    ProviderExclusionRestoreOutcome, TaskBoardExternalCreateBegin,
    TaskBoardExternalCreateFinalizeResult, TaskBoardExternalCreateIntent,
    TaskBoardExternalCreateStore, TaskBoardItem, TaskBoardStatus, TaskBoardSyncConflict,
    TaskBoardSyncStore,
};
use harness_kernel::errors::CliError;

pub(super) struct ProviderSyncRunStore<'a> {
    db: &'a AsyncDaemonDbHandle,
    coordinator_fence: Option<Arc<dyn TaskBoardSyncCoordinatorFence>>,
    coordinator_cancelled: AtomicBool,
}

impl<'a> ProviderSyncRunStore<'a> {
    pub(super) fn new(
        db: &'a AsyncDaemonDbHandle,
        coordinator_fence: Option<Arc<dyn TaskBoardSyncCoordinatorFence>>,
    ) -> Self {
        Self {
            db,
            coordinator_fence,
            coordinator_cancelled: AtomicBool::new(false),
        }
    }
}

#[async_trait]
impl TaskBoardExternalCreateStore for ProviderSyncRunStore<'_> {
    async fn begin_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        scope_id: &str,
        provider_target: &str,
    ) -> Result<TaskBoardExternalCreateBegin, CliError> {
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::begin_external_create_intent(
            self.db,
            item_id,
            provider,
            scope_id,
            provider_target,
        )
        .await
    }

    async fn record_external_create_outcome(
        &self,
        intent: &TaskBoardExternalCreateIntent,
        outcome: &ExternalCreateOutcome,
        provider_baseline: &ExternalRef,
    ) -> Result<TaskBoardExternalCreateIntent, CliError> {
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::record_external_create_outcome(
            self.db,
            intent,
            outcome,
            provider_baseline,
        )
        .await
    }

    async fn finalize_external_create_intent(
        &self,
        intent: &TaskBoardExternalCreateIntent,
    ) -> Result<TaskBoardExternalCreateFinalizeResult, CliError> {
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::finalize_external_create_intent(
            self.db, intent,
        )
        .await
    }

    async fn list_created_external_create_intents(
        &self,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::list_created_external_create_intents(
            self.db,
        )
        .await
    }

    async fn list_in_flight_external_create_intents(
        &self,
        provider: ExternalProvider,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::list_in_flight_external_create_intents(
            self.db, provider,
        )
        .await
    }

    async fn external_create_intent_by_create_key(
        &self,
        provider: ExternalProvider,
        create_key: &str,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::external_create_intent_by_create_key(
            self.db, provider, create_key,
        )
        .await
    }

    async fn list_pending_external_create_follow_ups(
        &self,
        provider: Option<ExternalProvider>,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::list_pending_external_create_follow_ups(
            self.db, provider,
        )
        .await
    }
}

#[async_trait]
impl TaskBoardSyncStore for ProviderSyncRunStore<'_> {
    async fn list_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::list_items(self.db, status).await
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::list_items_including_deleted(self.db).await
    }

    async fn list_item_snapshots_including_deleted(
        &self,
    ) -> Result<Vec<TaskBoardSyncItemSnapshot>, CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::list_item_snapshots_including_deleted(self.db)
            .await
    }

    async fn create_item(&self, item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::create_item(self.db, item).await
    }

    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::update_item(self.db, expected_item, patch)
            .await
    }

    async fn item_snapshot(&self, item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::item_snapshot(self.db, item_id).await
    }

    async fn hide_for_provider_exclusion(
        &self,
        item_id: &str,
        expected_revision: i64,
        patch: TaskBoardItemPatch,
        context: ProviderExclusionAuditContext,
        conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<Option<TaskBoardItem>, CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::hide_for_provider_exclusion(
            self.db,
            item_id,
            expected_revision,
            patch,
            context,
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
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::restore_from_provider_exclusion(
            self.db, expected, patch, context, conflicts,
        )
        .await
    }

    async fn provider_scope_state(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::provider_scope_state(
            self.db, provider, scope_id,
        )
        .await
    }

    async fn begin_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::begin_provider_scope_attempt(
            self.db, provider, scope_id, now,
        )
        .await
    }

    async fn renew_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        now: &str,
    ) -> Result<(), CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::renew_provider_scope_attempt(
            self.db, attempt, now,
        )
        .await
    }

    async fn check_coordinator_fence(
        &self,
    ) -> Result<TaskBoardSyncCoordinatorFenceDecision, CliError> {
        let Some(fence) = &self.coordinator_fence else {
            return Ok(TaskBoardSyncCoordinatorFenceDecision::Current);
        };
        let decision = fence.check().await?;
        if matches!(
            &decision,
            TaskBoardSyncCoordinatorFenceDecision::Cancelled(_)
        ) {
            self.coordinator_cancelled.store(true, Ordering::SeqCst);
        }
        Ok(decision)
    }

    fn coordinator_cancelled(&self) -> bool {
        self.coordinator_cancelled.load(Ordering::SeqCst)
    }

    async fn release_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        released_at: &str,
    ) -> Result<(), CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::release_provider_scope_attempt(
            self.db,
            attempt,
            released_at,
        )
        .await
    }

    async fn complete_provider_scope_success(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        base_revision: Option<&str>,
        completed_at: &str,
    ) -> Result<(), CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::complete_provider_scope_success(
            self.db,
            attempt,
            base_revision,
            completed_at,
        )
        .await
    }

    async fn complete_provider_scope_failure(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::complete_provider_scope_failure(
            self.db,
            attempt,
            completed_at,
        )
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
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::replace_open_sync_conflicts(
            self.db,
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
        <AsyncDaemonDbHandle as TaskBoardSyncStore>::supersede_open_sync_conflicts(
            self.db,
            item_id,
            provider,
            external_ref,
            item_revision,
            resolved_fields,
        )
        .await
    }
}
