//! Shared sync-client fixtures for the conflict-policy test group.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use harness_kernel::errors::CliError;

use harness::task_board::external::{
    ExternalProviderCapabilities, ExternalRevisionUpdate, ExternalSyncClient, ExternalTask,
    ExternalTaskRef, ExternalTaskUpdate, ExternalUpdateOutcome,
};
use harness::task_board::{
    ExternalProvider, ExternalRefSyncState, ExternalSyncField, TaskBoardItem, TaskBoardStatus,
};

pub(super) fn linked_item(
    id: &str,
    title: &str,
    body: &str,
    status: TaskBoardStatus,
) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.to_string(),
        title.to_string(),
        body.to_string(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = status;
    let mut reference = ExternalTaskRef::new(ExternalProvider::GitHub, "remote-1").into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        title: Some("Old title".to_string()),
        body: Some("Old body".to_string()),
        status: Some(TaskBoardStatus::Inbox),
        project_id: None,
        updated_at: Some("2026-05-14T00:00:00Z".to_string()),
        synced_at: Some("2026-05-14T00:00:00Z".to_string()),
        labels: Vec::new(),
    });
    item.external_refs.push(reference);
    item
}

pub(super) fn remote_task(
    external_id: &str,
    title: &str,
    body: &str,
    status: TaskBoardStatus,
) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, external_id),
        title: title.to_string(),
        body: body.to_string(),
        status,
        project_id: None,
        updated_at: Some("2026-05-14T01:00:00Z".to_string()),
        ..ExternalTask::default()
    }
}

pub(super) struct UpdateFakeSyncClient {
    provider: ExternalProvider,
    capabilities: ExternalProviderCapabilities,
    tasks: Vec<ExternalTask>,
    pub(super) updates: CapturedUpdates,
    precondition_failure: Option<ExternalTask>,
}

type CapturedUpdates = Arc<Mutex<Vec<(String, Vec<ExternalSyncField>)>>>;

impl UpdateFakeSyncClient {
    pub(super) fn new(
        provider: ExternalProvider,
        update_fields: Vec<ExternalSyncField>,
        tasks: Vec<ExternalTask>,
    ) -> Self {
        Self {
            provider,
            capabilities: ExternalProviderCapabilities::with_update_fields(update_fields),
            tasks,
            updates: Arc::new(Mutex::new(Vec::new())),
            precondition_failure: None,
        }
    }

    pub(super) fn with_precondition_failure(mut self, current: ExternalTask) -> Self {
        self.precondition_failure = Some(current);
        self
    }
}

#[async_trait]
impl ExternalSyncClient for UpdateFakeSyncClient {
    fn provider(&self) -> ExternalProvider {
        self.provider
    }

    fn capabilities(&self) -> ExternalProviderCapabilities {
        self.capabilities.clone()
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        Ok(self.tasks.clone())
    }

    async fn push_task(&self, item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        Ok(ExternalTaskRef::new(self.provider, item.id.clone()))
    }

    async fn update_task(
        &self,
        _item: &TaskBoardItem,
        reference: &ExternalTaskRef,
        update: ExternalTaskUpdate,
    ) -> Result<ExternalUpdateOutcome, CliError> {
        if let Some(current) = &self.precondition_failure
            && update.precondition_updated_at.is_some()
        {
            return Ok(ExternalUpdateOutcome::PreconditionFailed {
                current: current.clone(),
            });
        }
        self.updates
            .lock()
            .expect("updates")
            .push((reference.external_id.clone(), update.changed_fields));
        Ok(ExternalUpdateOutcome::Applied {
            reference: reference.clone(),
            provider_revision: ExternalRevisionUpdate::Set("provider-revision-2".into()),
        })
    }
}
