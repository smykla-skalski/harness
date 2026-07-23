use async_trait::async_trait;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalCreateOutcome, ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
    ExternalProviderScopeState,
};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{
    ExternalProvider, ExternalRef, ExternalSyncField, ProviderExclusionAuditContext,
    ProviderExclusionRestoreOutcome, TaskBoardExternalCreateBegin,
    TaskBoardExternalCreateFinalizeResult, TaskBoardExternalCreateIntent, TaskBoardItem,
    TaskBoardStatus, TaskBoardSyncConflict,
};

#[derive(Debug, Clone)]
pub(crate) struct TaskBoardSyncItemSnapshot {
    pub(crate) item: TaskBoardItem,
    pub(crate) item_revision: i64,
}

impl TaskBoardSyncItemSnapshot {
    pub(crate) const fn new(item: TaskBoardItem, item_revision: i64) -> Self {
        Self {
            item,
            item_revision,
        }
    }
}

pub(crate) enum TaskBoardSyncCoordinatorFenceDecision {
    Current,
    Cancelled(CliError),
}

#[async_trait]
pub(crate) trait TaskBoardSyncCoordinatorFence: Send + Sync {
    async fn check(&self) -> Result<TaskBoardSyncCoordinatorFenceDecision, CliError>;
}

#[async_trait]
pub(crate) trait TaskBoardExternalCreateStore: Send + Sync {
    async fn begin_external_create_intent(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _scope_id: &str,
        _provider_target: &str,
    ) -> Result<TaskBoardExternalCreateBegin, CliError> {
        Err(durable_external_create_store_required())
    }

    async fn record_external_create_outcome(
        &self,
        _intent: &TaskBoardExternalCreateIntent,
        _outcome: &ExternalCreateOutcome,
        _provider_baseline: &ExternalRef,
    ) -> Result<TaskBoardExternalCreateIntent, CliError> {
        Err(durable_external_create_store_required())
    }

    async fn finalize_external_create_intent(
        &self,
        _intent: &TaskBoardExternalCreateIntent,
    ) -> Result<TaskBoardExternalCreateFinalizeResult, CliError> {
        Err(durable_external_create_store_required())
    }

    async fn list_created_external_create_intents(
        &self,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        Err(durable_external_create_store_required())
    }

    async fn list_in_flight_external_create_intents(
        &self,
        _provider: ExternalProvider,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        Err(durable_external_create_store_required())
    }

    async fn external_create_intent_by_create_key(
        &self,
        _provider: ExternalProvider,
        _create_key: &str,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        Err(durable_external_create_store_required())
    }

    async fn list_pending_external_create_follow_ups(
        &self,
        _provider: Option<ExternalProvider>,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        Err(durable_external_create_store_required())
    }
}

#[async_trait]
pub(crate) trait TaskBoardSyncStore: TaskBoardExternalCreateStore {
    async fn list_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError>;
    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError>;

    /// Like [`list_items_including_deleted`](Self::list_items_including_deleted),
    /// but returns the row revision alongside each item so a batch-loaded
    /// provider-exclusion index can CAS the exact matched revision without a
    /// second point read.
    async fn list_item_snapshots_including_deleted(
        &self,
    ) -> Result<Vec<TaskBoardSyncItemSnapshot>, CliError> {
        Err(durable_external_create_store_required())
    }

    async fn create_item(&self, item: TaskBoardItem) -> Result<TaskBoardItem, CliError>;
    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError>;

    async fn item_snapshot(&self, item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError>;

    /// Tombstones an already-visible, pre-dispatch item because the provider
    /// now reports an exclusion label (duplicate/invalid/wontfix, bare or
    /// `triage/`-prefixed). `expected_revision` CASes against the exact row
    /// revision the caller last observed; `context` additionally re-verifies
    /// the exact stored provider link inside the transaction. `patch` (the
    /// normal reconciliation patch, minus parent) is applied before
    /// tombstoning so the row records the triggering label and a fresh
    /// `sync_state`. Returns `None`, doing nothing, when the item is not
    /// eligible to be hidden this way: already deleted, past pre-dispatch,
    /// otherwise dispatched/claimed work, or the row (or its provider link)
    /// moved since the caller last looked at it. `conflicts` follows the
    /// same publish-or-supersede contract as
    /// [`restore_from_provider_exclusion`](Self::restore_from_provider_exclusion),
    /// except a hide always tombstones regardless of it.
    async fn hide_for_provider_exclusion(
        &self,
        _item_id: &str,
        _expected_revision: i64,
        _patch: TaskBoardItemPatch,
        _context: ProviderExclusionAuditContext,
        _conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<Option<TaskBoardItem>, CliError> {
        Err(durable_external_create_store_required())
    }

    /// Restores a previously provider-exclusion-tombstoned item because the
    /// provider no longer reports an exclusion label. `expected` CASes
    /// against the exact snapshot (stored item id, row revision) the caller
    /// matched by provider reference; `context` additionally re-verifies the
    /// exact stored provider link inside the transaction. `patch` is the
    /// normal reconciliation patch (the same `reconciliation_patch` an
    /// ordinary pull reconcile computes, including the parent tri-state) so
    /// a restore preserves or conflicts exactly like any other reconcile
    /// instead of unconditionally overwriting local state. Local-only state
    /// this patch never touches -- planning approval, workflow, session,
    /// work item linkage, estimates, agent mode, a `Manual` lane anchor --
    /// stays exactly as stored. Returns `NotApplied` when `expected`'s row
    /// or provider link moved, or it is no longer tombstoned for provider
    /// exclusion, since the caller matched it. `conflicts` is `None` when
    /// this restore isn't under `Both`+`Report` at all (conflict state
    /// untouched); `Some(empty)` supersedes stale open conflict rows in the
    /// same transaction as the restore, which then proceeds normally;
    /// `Some(non-empty)` publishes them, CAS-gated on the exact tombstone
    /// revision/provider/stored ref, and returns `ConflictPublished` with
    /// the item left tombstoned.
    async fn restore_from_provider_exclusion(
        &self,
        _expected: TaskBoardSyncItemSnapshot,
        _patch: TaskBoardItemPatch,
        _context: ProviderExclusionAuditContext,
        _conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<ProviderExclusionRestoreOutcome, CliError> {
        Err(durable_external_create_store_required())
    }

    async fn provider_scope_state(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError>;

    async fn begin_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError>;

    async fn renew_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        now: &str,
    ) -> Result<(), CliError>;

    async fn check_coordinator_fence(
        &self,
    ) -> Result<TaskBoardSyncCoordinatorFenceDecision, CliError> {
        Ok(TaskBoardSyncCoordinatorFenceDecision::Current)
    }

    fn coordinator_cancelled(&self) -> bool {
        false
    }

    async fn release_provider_scope_attempt(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _released_at: &str,
    ) -> Result<(), CliError> {
        Err(CliErrorKind::workflow_io("neutral provider-scope release is unavailable").into())
    }

    async fn complete_provider_scope_success(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        base_revision: Option<&str>,
        completed_at: &str,
    ) -> Result<(), CliError>;

    async fn complete_provider_scope_failure(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError>;

    async fn replace_open_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError>;

    async fn supersede_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        _resolved_fields: &[ExternalSyncField],
    ) -> Result<(), CliError> {
        Err(CliErrorKind::workflow_io(
            "field-scoped task-board conflict supersession is unavailable",
        )
        .into())
    }
}

fn durable_external_create_store_required() -> CliError {
    CliErrorKind::workflow_io("durable task-board external-create storage is unavailable").into()
}
