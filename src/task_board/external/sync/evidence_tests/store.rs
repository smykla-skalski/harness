use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalProvider, ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
    ExternalProviderScopeState, ExternalSyncField, TaskBoardSyncItemSnapshot,
};
use crate::task_board::store::{TaskBoardItemPatch, apply_patch};
use crate::task_board::{
    TaskBoardExternalCreateStore, TaskBoardItem, TaskBoardStatus, TaskBoardSyncConflict,
    TaskBoardSyncStore,
};

#[derive(Clone, Copy)]
pub(super) enum UpdateBehavior {
    Apply,
    Concurrent,
    Fail(&'static str),
}

pub(super) struct EvidenceStore {
    items: Mutex<Vec<TaskBoardItem>>,
    successful_creates: usize,
    create_calls: AtomicUsize,
    pub(super) update_behavior: UpdateBehavior,
    pub(super) conflict_error: Option<&'static str>,
    pub(super) completion_error: Option<&'static str>,
    pub(super) completion_details: Option<&'static str>,
    pub(super) failure_completions: AtomicUsize,
}

impl TaskBoardExternalCreateStore for EvidenceStore {}

impl EvidenceStore {
    pub(super) fn with_create_limit(successful_creates: usize) -> Self {
        Self {
            items: Mutex::new(Vec::new()),
            successful_creates,
            create_calls: AtomicUsize::new(0),
            update_behavior: UpdateBehavior::Apply,
            conflict_error: None,
            completion_error: None,
            completion_details: None,
            failure_completions: AtomicUsize::new(0),
        }
    }

    pub(super) fn with_items(items: Vec<TaskBoardItem>) -> Self {
        Self {
            items: Mutex::new(items),
            successful_creates: usize::MAX,
            create_calls: AtomicUsize::new(0),
            update_behavior: UpdateBehavior::Apply,
            conflict_error: None,
            completion_error: None,
            completion_details: None,
            failure_completions: AtomicUsize::new(0),
        }
    }
}

#[async_trait]
impl TaskBoardSyncStore for EvidenceStore {
    async fn list_items(
        &self,
        _status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(self.items.lock().expect("items").clone())
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(self.items.lock().expect("items").clone())
    }

    async fn list_item_snapshots_including_deleted(
        &self,
    ) -> Result<Vec<TaskBoardSyncItemSnapshot>, CliError> {
        Ok(self
            .items
            .lock()
            .expect("items")
            .iter()
            .cloned()
            .map(|item| TaskBoardSyncItemSnapshot::new(item, 0))
            .collect())
    }

    async fn create_item(&self, item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        let call = self.create_calls.fetch_add(1, Ordering::SeqCst);
        if call >= self.successful_creates {
            return Err(CliErrorKind::workflow_io("local create persistence failed").into());
        }
        self.items.lock().expect("items").push(item.clone());
        Ok(item)
    }

    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        match self.update_behavior {
            UpdateBehavior::Apply => {
                let mut updated = expected_item.clone();
                apply_patch(&mut updated, patch);
                let mut items = self.items.lock().expect("items");
                if let Some(item) = items.iter_mut().find(|item| item.id == updated.id) {
                    item.clone_from(&updated);
                }
                Ok(updated)
            }
            UpdateBehavior::Concurrent => {
                Err(CliErrorKind::concurrent_modification("concurrent test update").into())
            }
            UpdateBehavior::Fail(message) => Err(CliErrorKind::workflow_io(message).into()),
        }
    }

    async fn item_snapshot(&self, item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError> {
        self.items
            .lock()
            .expect("items")
            .iter()
            .find(|item| item.id == item_id)
            .cloned()
            .map(|item| TaskBoardSyncItemSnapshot::new(item, 1))
            .ok_or_else(|| CliErrorKind::workflow_io("missing test item").into())
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
            ExternalProviderScopeAttempt::new(
                provider,
                scope_id.to_owned(),
                format!("test:{scope_id}"),
                true,
            ),
        ))
    }

    async fn renew_provider_scope_attempt(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _now: &str,
    ) -> Result<(), CliError> {
        Ok(())
    }

    async fn complete_provider_scope_success(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _base_revision: Option<&str>,
        _completed_at: &str,
    ) -> Result<(), CliError> {
        Ok(())
    }

    async fn complete_provider_scope_failure(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        self.failure_completions.fetch_add(1, Ordering::SeqCst);
        if let Some(message) = self.completion_error {
            let mut error: CliError = CliErrorKind::workflow_io(message).into();
            if let Some(details) = self.completion_details {
                error = error.with_details(details);
            }
            return Err(error);
        }
        Ok(ExternalProviderScopeState::default())
    }

    async fn replace_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        _conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        self.conflict_error.map_or(Ok(()), |message| {
            Err(CliErrorKind::workflow_io(message).into())
        })
    }

    async fn supersede_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        _resolved_fields: &[ExternalSyncField],
    ) -> Result<(), CliError> {
        self.conflict_error.map_or(Ok(()), |message| {
            Err(CliErrorKind::workflow_io(message).into())
        })
    }
}
