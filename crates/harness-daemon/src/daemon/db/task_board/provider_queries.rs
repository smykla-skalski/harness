//! The provider area's own interface onto [`AsyncDaemonDb`], scoped to
//! external-provider sync, exclusion, and create-intent queries.
//!
//! `task_board` doesn't own `AsyncDaemonDb` -- it's a sibling module's type --
//! so an inherent `impl AsyncDaemonDb` block for provider queries can never
//! move into a crate `task_board` doesn't share with `db`. A trait `task_board`
//! itself declares has no such problem: Rust's orphan rule only requires one
//! of the trait or the implementing type to be local, and the trait is. That
//! is what lets this one area's queries move into their own crate later
//! without dragging every other area's inherent impls along for the ride.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside `db/task_board`
//! has to change to keep calling them by the same name.

use async_trait::async_trait;

use super::items::TaskBoardMutation;
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{
    ExternalCreateOutcome, ExternalProvider, ExternalRef, ExternalSyncField,
    ProviderExclusionAuditContext, ProviderExclusionRestoreOutcome, TaskBoardExternalCreateBegin,
    TaskBoardExternalCreateFinalizeResult, TaskBoardExternalCreateIntent, TaskBoardSyncConflict,
};

#[async_trait]
pub(crate) trait ProviderQueries: Send + Sync {
    async fn hide_task_board_item_for_provider_exclusion(
        &self,
        item_id: &str,
        expected_revision: i64,
        patch: TaskBoardItemPatch,
        context: &ProviderExclusionAuditContext,
        conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<Option<TaskBoardMutation>, CliError>;

    async fn restore_task_board_item_for_provider_exclusion(
        &self,
        expected_item_id: &str,
        expected_revision: i64,
        patch: TaskBoardItemPatch,
        context: &ProviderExclusionAuditContext,
        conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<ProviderExclusionRestoreOutcome, CliError>;

    async fn begin_task_board_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        scope_id: &str,
        provider_target: &str,
    ) -> Result<TaskBoardExternalCreateBegin, CliError>;

    async fn record_task_board_external_create_outcome(
        &self,
        intent: &TaskBoardExternalCreateIntent,
        outcome: &ExternalCreateOutcome,
        provider_baseline: &ExternalRef,
    ) -> Result<TaskBoardExternalCreateIntent, CliError>;

    async fn list_pending_task_board_external_create_intents(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError>;

    async fn list_created_task_board_external_create_intents(
        &self,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError>;

    async fn list_in_flight_task_board_external_create_intents(
        &self,
        provider: ExternalProvider,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError>;

    async fn list_pending_task_board_external_create_follow_ups(
        &self,
        provider: Option<ExternalProvider>,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError>;

    async fn task_board_external_create_intent_by_create_key(
        &self,
        provider: ExternalProvider,
        create_key: &str,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError>;

    async fn task_board_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError>;

    async fn task_board_external_create_receipt(
        &self,
        item_id: &str,
        provider: ExternalProvider,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError>;

    async fn finalize_task_board_external_create_intent(
        &self,
        intent: &TaskBoardExternalCreateIntent,
    ) -> Result<TaskBoardExternalCreateFinalizeResult, CliError>;

    async fn complete_task_board_external_create_follow_ups(
        &self,
        intents: &[TaskBoardExternalCreateIntent],
    ) -> Result<Vec<HarnessMonitorAuditEvent>, CliError>;

    async fn task_board_provider_scope_state(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError>;

    async fn begin_task_board_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError>;

    async fn renew_task_board_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        now: &str,
    ) -> Result<(), CliError>;

    async fn release_task_board_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        released_at: &str,
    ) -> Result<(), CliError>;

    async fn complete_task_board_provider_scope_success(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        base_revision: Option<&str>,
        completed_at: &str,
    ) -> Result<(), CliError>;

    async fn complete_task_board_provider_scope_failure(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError>;

    async fn replace_open_task_board_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError>;

    async fn supersede_open_task_board_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        resolved_fields: &[ExternalSyncField],
    ) -> Result<(), CliError>;

    #[cfg(any(test, feature = "daemon-runtime"))]
    async fn open_task_board_sync_conflicts(&self) -> Result<Vec<TaskBoardSyncConflict>, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the free function that actually owns the
/// area's query logic, kept in the file the query has always lived in
/// (`provider_exclusion.rs`, `provider_sync.rs`, and so on) so this file
/// stays a pure interface plus wiring, not a 20-method dumping ground.
#[async_trait]
impl ProviderQueries for AsyncDaemonDb {
    async fn hide_task_board_item_for_provider_exclusion(
        &self,
        item_id: &str,
        expected_revision: i64,
        patch: TaskBoardItemPatch,
        context: &ProviderExclusionAuditContext,
        conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<Option<TaskBoardMutation>, CliError> {
        super::provider_exclusion::hide_task_board_item_for_provider_exclusion(
            self,
            item_id,
            expected_revision,
            patch,
            context,
            conflicts,
        )
        .await
    }

    async fn restore_task_board_item_for_provider_exclusion(
        &self,
        expected_item_id: &str,
        expected_revision: i64,
        patch: TaskBoardItemPatch,
        context: &ProviderExclusionAuditContext,
        conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<ProviderExclusionRestoreOutcome, CliError> {
        super::provider_exclusion::restore_task_board_item_for_provider_exclusion(
            self,
            expected_item_id,
            expected_revision,
            patch,
            context,
            conflicts,
        )
        .await
    }

    async fn begin_task_board_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        scope_id: &str,
        provider_target: &str,
    ) -> Result<TaskBoardExternalCreateBegin, CliError> {
        super::provider_external_creates::begin_task_board_external_create_intent(
            self,
            item_id,
            provider,
            scope_id,
            provider_target,
        )
        .await
    }

    async fn record_task_board_external_create_outcome(
        &self,
        intent: &TaskBoardExternalCreateIntent,
        outcome: &ExternalCreateOutcome,
        provider_baseline: &ExternalRef,
    ) -> Result<TaskBoardExternalCreateIntent, CliError> {
        super::provider_external_creates::record_task_board_external_create_outcome(
            self,
            intent,
            outcome,
            provider_baseline,
        )
        .await
    }

    async fn list_pending_task_board_external_create_intents(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        super::provider_external_creates::list_pending_task_board_external_create_intents(
            self, provider, scope_id,
        )
        .await
    }

    async fn list_created_task_board_external_create_intents(
        &self,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        super::provider_external_creates::list_created_task_board_external_create_intents(self)
            .await
    }

    async fn list_in_flight_task_board_external_create_intents(
        &self,
        provider: ExternalProvider,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        super::provider_external_creates::list_in_flight_task_board_external_create_intents(
            self, provider,
        )
        .await
    }

    async fn list_pending_task_board_external_create_follow_ups(
        &self,
        provider: Option<ExternalProvider>,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        super::provider_external_creates::list_pending_task_board_external_create_follow_ups(
            self, provider,
        )
        .await
    }

    async fn task_board_external_create_intent_by_create_key(
        &self,
        provider: ExternalProvider,
        create_key: &str,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        super::provider_external_creates::task_board_external_create_intent_by_create_key(
            self, provider, create_key,
        )
        .await
    }

    async fn task_board_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        super::provider_external_creates::task_board_external_create_intent(self, item_id, provider)
            .await
    }

    async fn task_board_external_create_receipt(
        &self,
        item_id: &str,
        provider: ExternalProvider,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        super::provider_external_creates::task_board_external_create_receipt(
            self, item_id, provider,
        )
        .await
    }

    async fn finalize_task_board_external_create_intent(
        &self,
        intent: &TaskBoardExternalCreateIntent,
    ) -> Result<TaskBoardExternalCreateFinalizeResult, CliError> {
        super::provider_external_create_finalize::finalize_task_board_external_create_intent(
            self, intent,
        )
        .await
    }

    async fn complete_task_board_external_create_follow_ups(
        &self,
        intents: &[TaskBoardExternalCreateIntent],
    ) -> Result<Vec<HarnessMonitorAuditEvent>, CliError> {
        super::provider_external_create_follow_up::complete_task_board_external_create_follow_ups(
            self, intents,
        )
        .await
    }

    async fn task_board_provider_scope_state(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        super::provider_sync::task_board_provider_scope_state(self, provider, scope_id).await
    }

    async fn begin_task_board_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        super::provider_sync::begin_task_board_provider_scope_attempt(self, provider, scope_id, now)
            .await
    }

    async fn renew_task_board_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        now: &str,
    ) -> Result<(), CliError> {
        super::provider_sync::renew_task_board_provider_scope_attempt(self, attempt, now).await
    }

    async fn release_task_board_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        released_at: &str,
    ) -> Result<(), CliError> {
        super::provider_sync::release_task_board_provider_scope_attempt(self, attempt, released_at)
            .await
    }

    async fn complete_task_board_provider_scope_success(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        base_revision: Option<&str>,
        completed_at: &str,
    ) -> Result<(), CliError> {
        super::provider_sync::complete_task_board_provider_scope_success(
            self,
            attempt,
            base_revision,
            completed_at,
        )
        .await
    }

    async fn complete_task_board_provider_scope_failure(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        super::provider_sync::complete_task_board_provider_scope_failure(
            self,
            attempt,
            completed_at,
        )
        .await
    }

    async fn replace_open_task_board_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        super::provider_sync_conflicts::replace_open_task_board_sync_conflicts(
            self,
            item_id,
            provider,
            external_ref,
            item_revision,
            conflicts,
        )
        .await
    }

    async fn supersede_open_task_board_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        resolved_fields: &[ExternalSyncField],
    ) -> Result<(), CliError> {
        super::provider_sync_conflicts::supersede_open_task_board_sync_conflicts(
            self,
            item_id,
            provider,
            external_ref,
            item_revision,
            resolved_fields,
        )
        .await
    }

    #[cfg(any(test, feature = "daemon-runtime"))]
    async fn open_task_board_sync_conflicts(&self) -> Result<Vec<TaskBoardSyncConflict>, CliError> {
        super::provider_sync_conflicts::open_task_board_sync_conflicts(self).await
    }
}
