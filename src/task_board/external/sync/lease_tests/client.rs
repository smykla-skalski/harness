use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;

use crate::errors::CliError;
use crate::task_board::external::{
    ExternalCreateLease, ExternalCreateProbe, ExternalCreateRecoveryClient, ExternalCreateRequest,
};
use crate::task_board::{
    ExternalProvider, ExternalSyncClient, ExternalTask, ExternalTaskRef, TaskBoardItem,
    TaskBoardStatus,
};

pub(super) struct DurableCreateClient {
    provider: ExternalProvider,
    target: &'static str,
    calls: Arc<AtomicUsize>,
}

impl DurableCreateClient {
    pub(super) fn new(
        provider: ExternalProvider,
        target: &'static str,
        calls: Arc<AtomicUsize>,
    ) -> Self {
        Self {
            provider,
            target,
            calls,
        }
    }
}

#[async_trait]
impl ExternalSyncClient for DurableCreateClient {
    fn provider(&self) -> ExternalProvider {
        self.provider
    }

    fn external_create_recovery(&self) -> Option<&dyn ExternalCreateRecoveryClient> {
        Some(self)
    }

    fn scope_id(&self) -> String {
        self.target.into()
    }

    fn scope_for_item(&self, _item: &TaskBoardItem) -> String {
        self.target.into()
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        Ok(Vec::new())
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("durable creation uses the recovery capability")
    }
}

#[async_trait]
impl ExternalCreateRecoveryClient for DurableCreateClient {
    fn provider(&self) -> ExternalProvider {
        self.provider
    }

    fn supports_target(&self, provider_target: &str) -> bool {
        provider_target == self.target
    }

    async fn create_started(
        &self,
        request: &ExternalCreateRequest,
        lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalTask, CliError> {
        lease.renew().await?;
        self.calls.fetch_add(1, Ordering::SeqCst);
        let external_id = match self.provider {
            ExternalProvider::GitHub => format!("{}#17", request.provider_target()),
            ExternalProvider::Todoist => "remote-created".into(),
        };
        Ok(ExternalTask {
            reference: ExternalTaskRef::new(self.provider, external_id),
            title: request.title().into(),
            body: request.body().into(),
            status: TaskBoardStatus::Backlog,
            project_id: (self.provider == ExternalProvider::Todoist)
                .then(|| request.provider_target().into()),
            updated_at: Some("provider-revision-1".into()),
            ..ExternalTask::default()
        })
    }

    async fn recover_existing(
        &self,
        _request: &ExternalCreateRequest,
        _lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalCreateProbe, CliError> {
        unreachable!("newly admitted create test")
    }

    fn extract_create_key(&self, task: &mut ExternalTask) -> Result<Option<String>, CliError> {
        let Some((body, create_key)) = task.body.rsplit_once("\ncreate-key:") else {
            return Ok(None);
        };
        let body = body.to_owned();
        let create_key = create_key.to_owned();
        task.body = body;
        Ok(Some(create_key))
    }
}
