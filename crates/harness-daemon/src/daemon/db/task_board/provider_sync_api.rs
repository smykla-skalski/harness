//! `AsyncDaemonDb`'s inherent, externally-callable methods for the
//! provider-sync and external-create areas now implemented in
//! `harness-task-board-provider-sync`. These stay here rather than moving
//! with the query logic: an inherent `impl AsyncDaemonDb` block can only
//! live in the crate that defines `AsyncDaemonDb`, so every method here is
//! a thin forward into [`ProviderQueries`], matching the pattern
//! `provider_queries.rs`'s own doc comment describes. Kept in one file,
//! separate from `provider_queries.rs` itself, so that file stays focused
//! on the trait and its one impl rather than also carrying every public
//! call site.

use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
};
use crate::task_board::{
    ExternalCreateOutcome, ExternalProvider, ExternalRef, ExternalSyncField,
    TaskBoardExternalCreateBegin, TaskBoardExternalCreateFinalizeResult,
    TaskBoardExternalCreateIntent, TaskBoardSyncConflict,
};

use super::provider_queries::ProviderQueries;

impl AsyncDaemonDb {
    /// # Errors
    /// Returns [`CliError`] when the read fails.
    pub async fn task_board_provider_scope_state(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        <Self as ProviderQueries>::task_board_provider_scope_state(self, provider, scope_id).await
    }

    pub(crate) async fn begin_task_board_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        <Self as ProviderQueries>::begin_task_board_provider_scope_attempt(
            self, provider, scope_id, now,
        )
        .await
    }

    pub(crate) async fn renew_task_board_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        now: &str,
    ) -> Result<(), CliError> {
        <Self as ProviderQueries>::renew_task_board_provider_scope_attempt(self, attempt, now).await
    }

    pub(crate) async fn release_task_board_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        released_at: &str,
    ) -> Result<(), CliError> {
        <Self as ProviderQueries>::release_task_board_provider_scope_attempt(
            self,
            attempt,
            released_at,
        )
        .await
    }

    pub(crate) async fn complete_task_board_provider_scope_success(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        base_revision: Option<&str>,
        completed_at: &str,
    ) -> Result<(), CliError> {
        <Self as ProviderQueries>::complete_task_board_provider_scope_success(
            self,
            attempt,
            base_revision,
            completed_at,
        )
        .await
    }

    pub(crate) async fn complete_task_board_provider_scope_failure(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        <Self as ProviderQueries>::complete_task_board_provider_scope_failure(
            self,
            attempt,
            completed_at,
        )
        .await
    }

    /// # Errors
    /// Returns [`CliError`] when the item revision has moved or the write fails.
    pub async fn replace_open_task_board_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        <Self as ProviderQueries>::replace_open_task_board_sync_conflicts(
            self,
            item_id,
            provider,
            external_ref,
            item_revision,
            conflicts,
        )
        .await
    }

    pub(crate) async fn supersede_open_task_board_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        resolved_fields: &[ExternalSyncField],
    ) -> Result<(), CliError> {
        <Self as ProviderQueries>::supersede_open_task_board_sync_conflicts(
            self,
            item_id,
            provider,
            external_ref,
            item_revision,
            resolved_fields,
        )
        .await
    }

    /// # Errors
    /// Returns [`CliError`] when the read fails.
    // `pub`, not `pub(crate)`, and gated the same way as `daemon::state::test_support`:
    // `tests/integration_daemon.rs`'s task-board sync scenarios read open
    // conflicts back after a sync the same way this crate's own unit tests do,
    // and that binary links `harness` as an ordinary dependency where
    // `cfg(test)` is never set.
    #[cfg(any(test, feature = "daemon-runtime"))]
    pub async fn open_task_board_sync_conflicts(
        &self,
    ) -> Result<Vec<TaskBoardSyncConflict>, CliError> {
        <Self as ProviderQueries>::open_task_board_sync_conflicts(self).await
    }

    pub(crate) async fn begin_task_board_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        scope_id: &str,
        provider_target: &str,
    ) -> Result<TaskBoardExternalCreateBegin, CliError> {
        <Self as ProviderQueries>::begin_task_board_external_create_intent(
            self,
            item_id,
            provider,
            scope_id,
            provider_target,
        )
        .await
    }

    pub(crate) async fn record_task_board_external_create_outcome(
        &self,
        intent: &TaskBoardExternalCreateIntent,
        outcome: &ExternalCreateOutcome,
        provider_baseline: &ExternalRef,
    ) -> Result<TaskBoardExternalCreateIntent, CliError> {
        <Self as ProviderQueries>::record_task_board_external_create_outcome(
            self,
            intent,
            outcome,
            provider_baseline,
        )
        .await
    }

    pub(crate) async fn list_pending_task_board_external_create_intents(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        <Self as ProviderQueries>::list_pending_task_board_external_create_intents(
            self, provider, scope_id,
        )
        .await
    }

    pub(crate) async fn list_created_task_board_external_create_intents(
        &self,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        <Self as ProviderQueries>::list_created_task_board_external_create_intents(self).await
    }

    pub(crate) async fn list_in_flight_task_board_external_create_intents(
        &self,
        provider: ExternalProvider,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        <Self as ProviderQueries>::list_in_flight_task_board_external_create_intents(self, provider)
            .await
    }

    pub(crate) async fn list_pending_task_board_external_create_follow_ups(
        &self,
        provider: Option<ExternalProvider>,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        <Self as ProviderQueries>::list_pending_task_board_external_create_follow_ups(
            self, provider,
        )
        .await
    }

    pub(crate) async fn task_board_external_create_intent_by_create_key(
        &self,
        provider: ExternalProvider,
        create_key: &str,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        <Self as ProviderQueries>::task_board_external_create_intent_by_create_key(
            self, provider, create_key,
        )
        .await
    }

    pub(crate) async fn task_board_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        <Self as ProviderQueries>::task_board_external_create_intent(self, item_id, provider).await
    }

    /// # Errors
    /// Returns [`CliError`] when the read fails.
    pub async fn task_board_external_create_receipt(
        &self,
        item_id: &str,
        provider: ExternalProvider,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        <Self as ProviderQueries>::task_board_external_create_receipt(self, item_id, provider).await
    }

    pub(crate) async fn finalize_task_board_external_create_intent(
        &self,
        intent: &TaskBoardExternalCreateIntent,
    ) -> Result<TaskBoardExternalCreateFinalizeResult, CliError> {
        <Self as ProviderQueries>::finalize_task_board_external_create_intent(self, intent).await
    }

    pub(crate) async fn complete_task_board_external_create_follow_ups(
        &self,
        intents: &[TaskBoardExternalCreateIntent],
    ) -> Result<Vec<HarnessMonitorAuditEvent>, CliError> {
        <Self as ProviderQueries>::complete_task_board_external_create_follow_ups(self, intents)
            .await
    }
}
