use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use async_trait::async_trait;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
    TaskBoardExternalCreateStore, TaskBoardSyncCoordinatorFenceDecision, TaskBoardSyncItemSnapshot,
    TaskBoardSyncStore,
};
use crate::task_board::store::{TaskBoardItemPatch, apply_patch};
use crate::task_board::{
    ExternalCreateOutcome, ExternalProvider, ExternalRef, ExternalSyncField,
    TaskBoardExternalCreateBegin, TaskBoardExternalCreateEvidence, TaskBoardExternalCreateExisting,
    TaskBoardExternalCreateFinalizeDisposition, TaskBoardExternalCreateFinalizeResult,
    TaskBoardExternalCreateIntent, TaskBoardExternalCreateIntentState,
    TaskBoardExternalCreateReceipt, TaskBoardExternalCreateSnapshot, TaskBoardItem,
    TaskBoardStatus, TaskBoardSyncConflict,
};

pub(super) struct DurableCreateStore {
    pub(super) item: Mutex<TaskBoardItem>,
    intent: Mutex<Option<TaskBoardExternalCreateIntent>>,
    renew_error: Option<(&'static str, bool, usize)>,
    finalize_error: Option<&'static str>,
    completion_error: Option<&'static str>,
    conflict_error: Option<&'static str>,
    coordinator_cancel_error: Option<&'static str>,
    status_on_finalize: Option<TaskBoardStatus>,
    coordinator_cancelled: AtomicBool,
    pub(super) failure_completions: AtomicUsize,
    pub(super) neutral_releases: AtomicUsize,
    pub(super) coordinator_checks: AtomicUsize,
    pub(super) record_calls: AtomicUsize,
    pub(super) finalize_calls: AtomicUsize,
    pub(super) supersede_calls: AtomicUsize,
    pub(super) update_calls: AtomicUsize,
    pub(super) tombstone_list_calls: AtomicUsize,
    renew_calls: AtomicUsize,
    pub(super) resolved_fields: Mutex<Vec<ExternalSyncField>>,
    pub(super) success_base_revision: Mutex<Option<Option<String>>>,
    pub(super) fence_order: Mutex<Vec<&'static str>>,
}

impl DurableCreateStore {
    pub(super) fn stale_lease(item: TaskBoardItem) -> Self {
        Self::new(
            item,
            Some(("provider scope lease was replaced", false, 0)),
            None,
            Some("stale provider scope cannot be finalized"),
            None,
            None,
        )
    }

    pub(super) fn io_lease_failure(item: TaskBoardItem) -> Self {
        Self::new(
            item,
            Some(("lease storage unavailable", true, 1)),
            None,
            None,
            None,
            None,
        )
    }

    pub(super) fn cleanup_failure(item: TaskBoardItem) -> Self {
        Self::new(
            item,
            None,
            None,
            None,
            Some("conflict cleanup failed"),
            None,
        )
    }

    pub(super) fn done_during_finalize(item: TaskBoardItem) -> Self {
        Self::new(item, None, None, None, None, Some(TaskBoardStatus::Done))
    }

    pub(super) fn finalize_failure(item: TaskBoardItem) -> Self {
        Self::new(item, None, Some("local CAS failed"), None, None, None)
    }

    pub(super) fn coordinator_cancelled(item: TaskBoardItem) -> Self {
        let mut store = Self::new(item, None, None, None, None, None);
        store.coordinator_cancel_error = Some("coordinator run was cancelled");
        store
    }

    pub(super) fn new(
        item: TaskBoardItem,
        renew_error: Option<(&'static str, bool, usize)>,
        finalize_error: Option<&'static str>,
        completion_error: Option<&'static str>,
        conflict_error: Option<&'static str>,
        status_on_finalize: Option<TaskBoardStatus>,
    ) -> Self {
        Self {
            item: Mutex::new(item),
            intent: Mutex::new(None),
            renew_error,
            finalize_error,
            completion_error,
            conflict_error,
            coordinator_cancel_error: None,
            status_on_finalize,
            coordinator_cancelled: AtomicBool::new(false),
            failure_completions: AtomicUsize::new(0),
            neutral_releases: AtomicUsize::new(0),
            coordinator_checks: AtomicUsize::new(0),
            record_calls: AtomicUsize::new(0),
            finalize_calls: AtomicUsize::new(0),
            supersede_calls: AtomicUsize::new(0),
            update_calls: AtomicUsize::new(0),
            tombstone_list_calls: AtomicUsize::new(0),
            renew_calls: AtomicUsize::new(0),
            resolved_fields: Mutex::new(Vec::new()),
            success_base_revision: Mutex::new(None),
            fence_order: Mutex::new(Vec::new()),
        }
    }

    pub(super) fn intent(&self) -> TaskBoardExternalCreateIntent {
        self.intent
            .lock()
            .expect("intent")
            .clone()
            .expect("persisted intent")
    }
}

#[async_trait]
impl TaskBoardExternalCreateStore for DurableCreateStore {
    async fn begin_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        scope_id: &str,
        provider_target: &str,
    ) -> Result<TaskBoardExternalCreateBegin, CliError> {
        let item = self.item.lock().expect("item").clone();
        let mut stored = self.intent.lock().expect("intent");
        if let Some(intent) = stored.as_ref() {
            let existing = match intent.state {
                TaskBoardExternalCreateIntentState::InFlight => {
                    TaskBoardExternalCreateExisting::Recover(intent.clone())
                }
                TaskBoardExternalCreateIntentState::Created(_) => {
                    TaskBoardExternalCreateExisting::Finalize(intent.clone())
                }
                TaskBoardExternalCreateIntentState::Attached(_) => {
                    TaskBoardExternalCreateExisting::Attached(intent.clone())
                }
            };
            return Ok(TaskBoardExternalCreateBegin::Existing(existing));
        }
        assert_eq!(item_id, item.id);
        let mut changed_fields = vec![
            ExternalSyncField::Title,
            ExternalSyncField::Body,
            ExternalSyncField::Status,
        ];
        if provider != ExternalProvider::GitHub && item.project_id.is_some() {
            changed_fields.push(ExternalSyncField::Project);
        }
        let intent = TaskBoardExternalCreateIntent {
            intent_id: format!("intent-{item_id}"),
            item_id: item_id.into(),
            item_revision: 1,
            provider,
            scope_id: scope_id.into(),
            create_key: format!("create-key-{item_id}"),
            snapshot: TaskBoardExternalCreateSnapshot {
                title: item.title,
                body: item.body,
                status: item.status,
                project_id: item.project_id,
                execution_repository: item.execution_repository,
                provider_target: provider_target.into(),
            },
            changed_fields,
            state: TaskBoardExternalCreateIntentState::InFlight,
            created_at: "2026-07-16T10:00:00Z".into(),
            updated_at: "2026-07-16T10:00:00Z".into(),
        };
        *stored = Some(intent.clone());
        Ok(TaskBoardExternalCreateBegin::Started(intent))
    }

    async fn record_external_create_outcome(
        &self,
        intent: &TaskBoardExternalCreateIntent,
        outcome: &ExternalCreateOutcome,
        provider_baseline: &ExternalRef,
    ) -> Result<TaskBoardExternalCreateIntent, CliError> {
        self.record_calls.fetch_add(1, Ordering::SeqCst);
        let mut stored = self.intent.lock().expect("intent");
        let mut recorded = stored.clone().expect("persisted intent");
        assert_eq!(recorded.intent_id, intent.intent_id);
        recorded.state = TaskBoardExternalCreateIntentState::Created(Box::new(
            TaskBoardExternalCreateEvidence {
                outcome: outcome.clone(),
                provider_baseline: provider_baseline.clone(),
                recorded_at: "2026-07-16T10:00:00Z".into(),
            },
        ));
        *stored = Some(recorded.clone());
        Ok(recorded)
    }

    async fn finalize_external_create_intent(
        &self,
        intent: &TaskBoardExternalCreateIntent,
    ) -> Result<TaskBoardExternalCreateFinalizeResult, CliError> {
        self.finalize_calls.fetch_add(1, Ordering::SeqCst);
        if let Some(message) = self.finalize_error {
            return Err(CliErrorKind::concurrent_modification(message).into());
        }
        let mut stored = self.intent.lock().expect("intent");
        let current = stored.clone().expect("persisted intent");
        assert_eq!(current.intent_id, intent.intent_id);
        let evidence = current
            .created_evidence()
            .cloned()
            .expect("created evidence");
        let attached = TaskBoardExternalCreateIntent {
            state: TaskBoardExternalCreateIntentState::Attached(Box::new(
                TaskBoardExternalCreateReceipt {
                    evidence: evidence.clone(),
                    attached_at: "2026-07-16T10:00:00Z".into(),
                    attached_item_revision: 2,
                },
            )),
            updated_at: "2026-07-16T10:00:00Z".into(),
            ..current
        };
        let mut linked = self.item.lock().expect("item").clone();
        if let Some(status) = self.status_on_finalize {
            linked.status = status;
        }
        linked.external_refs.push(evidence.provider_baseline);
        self.supersede_calls.fetch_add(1, Ordering::SeqCst);
        if let Some(message) = self.conflict_error {
            return Err(CliErrorKind::workflow_io(message).into());
        }
        self.resolved_fields
            .lock()
            .expect("resolved fields")
            .clone_from(&intent.changed_fields);
        self.item.lock().expect("item").clone_from(&linked);
        *stored = Some(attached.clone());
        Ok(TaskBoardExternalCreateFinalizeResult {
            intent: attached,
            item: Some(linked),
            item_revision: Some(2),
            disposition: TaskBoardExternalCreateFinalizeDisposition::Attached,
        })
    }

    async fn external_create_intent_by_create_key(
        &self,
        provider: ExternalProvider,
        create_key: &str,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        Ok(self
            .intent
            .lock()
            .expect("intent")
            .as_ref()
            .filter(|intent| intent.provider == provider && intent.create_key == create_key)
            .cloned())
    }

    async fn list_created_external_create_intents(
        &self,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        Ok(self
            .intent
            .lock()
            .expect("intent")
            .iter()
            .filter(|intent| matches!(intent.state, TaskBoardExternalCreateIntentState::Created(_)))
            .cloned()
            .collect())
    }

    async fn list_in_flight_external_create_intents(
        &self,
        provider: ExternalProvider,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        Ok(self
            .intent
            .lock()
            .expect("intent")
            .iter()
            .filter(|intent| {
                intent.provider == provider
                    && matches!(intent.state, TaskBoardExternalCreateIntentState::InFlight)
            })
            .cloned()
            .collect())
    }

    async fn list_pending_external_create_follow_ups(
        &self,
        provider: Option<ExternalProvider>,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        Ok(self
            .intent
            .lock()
            .expect("intent")
            .iter()
            .filter(|intent| {
                provider.is_none_or(|provider| intent.provider == provider)
                    && matches!(
                        intent.state,
                        TaskBoardExternalCreateIntentState::Attached(_)
                    )
            })
            .cloned()
            .collect())
    }
}

#[async_trait]
impl TaskBoardSyncStore for DurableCreateStore {
    async fn list_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        let item = self.item.lock().expect("item").clone();
        Ok(
            (!item.is_deleted() && status.is_none_or(|target| item.status == target))
                .then_some(item)
                .into_iter()
                .collect(),
        )
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        self.tombstone_list_calls.fetch_add(1, Ordering::SeqCst);
        Ok(vec![self.item.lock().expect("item").clone()])
    }

    async fn list_item_snapshots_including_deleted(
        &self,
    ) -> Result<Vec<TaskBoardSyncItemSnapshot>, CliError> {
        Ok(vec![TaskBoardSyncItemSnapshot::new(
            self.item.lock().expect("item").clone(),
            0,
        )])
    }

    async fn create_item(&self, _item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        unreachable!("push-only create test")
    }

    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        let mut current = self.item.lock().expect("item");
        if *current != *expected_item {
            return Err(CliErrorKind::concurrent_modification(
                "test item changed before provider reconciliation",
            )
            .into());
        }
        let mut updated = current.clone();
        apply_patch(&mut updated, patch);
        self.update_calls.fetch_add(1, Ordering::SeqCst);
        current.clone_from(&updated);
        Ok(updated)
    }

    async fn item_snapshot(&self, _item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError> {
        Ok(TaskBoardSyncItemSnapshot::new(
            self.item.lock().expect("item").clone(),
            2,
        ))
    }

    async fn provider_scope_state(
        &self,
        _provider: ExternalProvider,
        _scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        Ok(ExternalProviderScopeState::default())
    }

    async fn begin_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        _now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        Ok(ExternalProviderScopeAttemptDecision::Started(
            ExternalProviderScopeAttempt::new(provider, scope_id.into(), "test-fence".into(), true),
        ))
    }

    async fn renew_provider_scope_attempt(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _now: &str,
    ) -> Result<(), CliError> {
        self.fence_order
            .lock()
            .expect("fence order")
            .push("provider");
        let call = self.renew_calls.fetch_add(1, Ordering::SeqCst);
        match self.renew_error {
            Some((message, true, fail_at)) if call == fail_at => {
                Err(CliErrorKind::workflow_io(message).into())
            }
            Some((message, false, fail_at)) if call == fail_at => {
                Err(CliErrorKind::concurrent_modification(message).into())
            }
            Some(_) | None => Ok(()),
        }
    }

    async fn check_coordinator_fence(
        &self,
    ) -> Result<TaskBoardSyncCoordinatorFenceDecision, CliError> {
        self.coordinator_checks.fetch_add(1, Ordering::SeqCst);
        self.fence_order
            .lock()
            .expect("fence order")
            .push("coordinator");
        self.coordinator_cancel_error.map_or_else(
            || Ok(TaskBoardSyncCoordinatorFenceDecision::Current),
            |message| {
                self.coordinator_cancelled.store(true, Ordering::SeqCst);
                Ok(TaskBoardSyncCoordinatorFenceDecision::Cancelled(
                    CliErrorKind::concurrent_modification(message).into(),
                ))
            },
        )
    }

    fn coordinator_cancelled(&self) -> bool {
        self.coordinator_cancelled.load(Ordering::SeqCst)
    }

    async fn release_provider_scope_attempt(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _released_at: &str,
    ) -> Result<(), CliError> {
        self.neutral_releases.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    async fn complete_provider_scope_success(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        base_revision: Option<&str>,
        _completed_at: &str,
    ) -> Result<(), CliError> {
        *self.success_base_revision.lock().expect("base revision") =
            Some(base_revision.map(str::to_owned));
        Ok(())
    }

    async fn complete_provider_scope_failure(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        self.failure_completions.fetch_add(1, Ordering::SeqCst);
        self.completion_error.map_or_else(
            || Ok(ExternalProviderScopeState::default()),
            |message| Err(CliErrorKind::concurrent_modification(message).into()),
        )
    }

    async fn replace_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        _conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        unreachable!("create evidence is durable, not synthesized as a conflict")
    }

    async fn supersede_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        resolved_fields: &[ExternalSyncField],
    ) -> Result<(), CliError> {
        self.supersede_calls.fetch_add(1, Ordering::SeqCst);
        *self.resolved_fields.lock().expect("resolved fields") = resolved_fields.to_vec();
        self.conflict_error.map_or(Ok(()), |message| {
            Err(CliErrorKind::workflow_io(message).into())
        })
    }
}
