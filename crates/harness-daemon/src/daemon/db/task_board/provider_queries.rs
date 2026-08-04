//! The provider area's own interface onto [`AsyncDaemonDb`], scoped to
//! external-provider sync, exclusion, and create-intent queries.
//!
//! `task_board` doesn't own `AsyncDaemonDb` -- it's a sibling module's type --
//! so an inherent `impl AsyncDaemonDb` block for provider queries can never
//! move into a crate `task_board` doesn't share with `db`. A trait `task_board`
//! itself declares has no such problem: Rust's orphan rule only requires one
//! of the trait or the implementing type to be local, and the trait is. That
//! is what let most of this area's query logic move into
//! `harness-task-board-provider-sync`: this trait, and its one impl below,
//! stay here (an inherent-adjacent impl for a foreign type still needs to
//! live somewhere that can see both), but the delegate functions each
//! method forwards to now mostly live in that crate instead of a sibling
//! file in this one. `provider_exclusion`'s two methods still forward to
//! `super::provider_exclusion` -- that file didn't move, see its own
//! module doc for why.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside `db/task_board`
//! has to change to keep calling them by the same name.

use super::items::TaskBoardMutation;
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::daemon::db_handle::AsyncDaemonDbHandle;
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

pub(crate) trait ProviderQueries: Send + Sync {
    async fn hide_task_board_item_for_provider_exclusion(
        &self,
        item_id: &str,
        expected_revision: i64,
        patch: TaskBoardItemPatch,
        context: &ProviderExclusionAuditContext,
        conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<Option<TaskBoardMutation>, CliError>;

    /// Restores a previously provider-exclusion-tombstoned item because the
    /// provider no longer reports an exclusion label. `expected_revision`
    /// and `context`'s stored provider ref both CAS against the exact state
    /// the caller matched by; either moving, or the row no longer carrying
    /// the `ProviderExclusion` cause, yields `NotApplied`. `patch` is the
    /// normal reconciliation patch (parent tri-state included) applied the
    /// same way any other reconcile applies one, so local state it never
    /// mentions -- planning approval, workflow, session, work item linkage,
    /// estimates, agent mode, a `Manual` lane anchor -- stays exactly as
    /// stored. A rejected parent assignment (self, cycle, missing) is
    /// isolated to that field, same as ordinary reconcile; the rest of the
    /// patch still applies. A retained `BuiltInV1` decision's placement
    /// effect is reconciled here too, without duplicating decision history,
    /// and the whole restore is exactly one typed audit event. `conflicts`
    /// is `None` outside `Both`+`Report` (conflict state untouched),
    /// `Some(empty)` to supersede stale open rows in this same transaction
    /// before the restore proceeds, or `Some(non-empty)` to publish
    /// conflicts and return `ConflictPublished` without restoring, leaving
    /// the tombstone in place.
    ///
    /// # Errors
    /// Returns [`CliError`] when the item does not exist or the restore fails.
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
        harness_task_board_provider_sync::begin_task_board_external_create_intent(
            &AsyncDaemonDbHandle(self.clone()),
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
        harness_task_board_provider_sync::record_task_board_external_create_outcome(
            &AsyncDaemonDbHandle(self.clone()),
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
        harness_task_board_provider_sync::list_pending_task_board_external_create_intents(
            &AsyncDaemonDbHandle(self.clone()),
            provider,
            scope_id,
        )
        .await
    }

    async fn list_created_task_board_external_create_intents(
        &self,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        harness_task_board_provider_sync::list_created_task_board_external_create_intents(
            &AsyncDaemonDbHandle(self.clone()),
        )
        .await
    }

    async fn list_in_flight_task_board_external_create_intents(
        &self,
        provider: ExternalProvider,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        harness_task_board_provider_sync::list_in_flight_task_board_external_create_intents(
            &AsyncDaemonDbHandle(self.clone()),
            provider,
        )
        .await
    }

    async fn list_pending_task_board_external_create_follow_ups(
        &self,
        provider: Option<ExternalProvider>,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        harness_task_board_provider_sync::list_pending_task_board_external_create_follow_ups(
            &AsyncDaemonDbHandle(self.clone()),
            provider,
        )
        .await
    }

    async fn task_board_external_create_intent_by_create_key(
        &self,
        provider: ExternalProvider,
        create_key: &str,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        harness_task_board_provider_sync::task_board_external_create_intent_by_create_key(
            &AsyncDaemonDbHandle(self.clone()),
            provider,
            create_key,
        )
        .await
    }

    async fn task_board_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        harness_task_board_provider_sync::task_board_external_create_intent(
            &AsyncDaemonDbHandle(self.clone()),
            item_id,
            provider,
        )
        .await
    }

    async fn task_board_external_create_receipt(
        &self,
        item_id: &str,
        provider: ExternalProvider,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        harness_task_board_provider_sync::task_board_external_create_receipt(
            &AsyncDaemonDbHandle(self.clone()),
            item_id,
            provider,
        )
        .await
    }

    async fn finalize_task_board_external_create_intent(
        &self,
        intent: &TaskBoardExternalCreateIntent,
    ) -> Result<TaskBoardExternalCreateFinalizeResult, CliError> {
        harness_task_board_provider_sync::finalize_task_board_external_create_intent(
            &AsyncDaemonDbHandle(self.clone()),
            intent,
        )
        .await
    }

    async fn complete_task_board_external_create_follow_ups(
        &self,
        intents: &[TaskBoardExternalCreateIntent],
    ) -> Result<Vec<HarnessMonitorAuditEvent>, CliError> {
        harness_task_board_provider_sync::complete_task_board_external_create_follow_ups(
            &AsyncDaemonDbHandle(self.clone()),
            intents,
        )
        .await
    }

    async fn task_board_provider_scope_state(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        harness_task_board_provider_sync::task_board_provider_scope_state(
            &AsyncDaemonDbHandle(self.clone()),
            provider,
            scope_id,
        )
        .await
    }

    async fn begin_task_board_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        harness_task_board_provider_sync::begin_task_board_provider_scope_attempt(
            &AsyncDaemonDbHandle(self.clone()),
            provider,
            scope_id,
            now,
        )
        .await
    }

    async fn renew_task_board_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        now: &str,
    ) -> Result<(), CliError> {
        harness_task_board_provider_sync::renew_task_board_provider_scope_attempt(
            &AsyncDaemonDbHandle(self.clone()),
            attempt,
            now,
        )
        .await
    }

    async fn release_task_board_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        released_at: &str,
    ) -> Result<(), CliError> {
        harness_task_board_provider_sync::release_task_board_provider_scope_attempt(
            &AsyncDaemonDbHandle(self.clone()),
            attempt,
            released_at,
        )
        .await
    }

    async fn complete_task_board_provider_scope_success(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        base_revision: Option<&str>,
        completed_at: &str,
    ) -> Result<(), CliError> {
        harness_task_board_provider_sync::complete_task_board_provider_scope_success(
            &AsyncDaemonDbHandle(self.clone()),
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
        harness_task_board_provider_sync::complete_task_board_provider_scope_failure(
            &AsyncDaemonDbHandle(self.clone()),
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
        harness_task_board_provider_sync::replace_open_task_board_sync_conflicts(
            &AsyncDaemonDbHandle(self.clone()),
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
        harness_task_board_provider_sync::supersede_open_task_board_sync_conflicts(
            &AsyncDaemonDbHandle(self.clone()),
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
        harness_task_board_provider_sync::open_task_board_sync_conflicts(&AsyncDaemonDbHandle(
            self.clone(),
        ))
        .await
    }
}
