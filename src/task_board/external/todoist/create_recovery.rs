use async_trait::async_trait;

use crate::errors::CliError;

use super::{TODOIST_ALL_SCOPE, TodoistCreateTaskRequest, TodoistSyncClient, non_empty_body};
use crate::task_board::external::{
    ExternalCreateLease, ExternalCreateProbe, ExternalCreateRecoveryClient, ExternalCreateRequest,
    ExternalProvider, ExternalTask,
};

#[async_trait]
impl ExternalCreateRecoveryClient for TodoistSyncClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::Todoist
    }

    fn supports_target(&self, provider_target: &str) -> bool {
        let provider_target = provider_target.trim();
        !provider_target.is_empty()
            && (self.project_filter().is_empty()
                || self
                    .project_filter()
                    .iter()
                    .any(|project_id| project_id.trim() == provider_target))
    }

    async fn create_started(
        &self,
        request: &ExternalCreateRequest,
        lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalTask, CliError> {
        lease.renew().await?;
        self.replay_create(request).await
    }

    async fn recover_existing(
        &self,
        request: &ExternalCreateRequest,
        lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalCreateProbe, CliError> {
        lease.renew().await?;
        self.replay_create(request)
            .await
            .map(|task| ExternalCreateProbe::Found(Box::new(task)))
    }
}

impl TodoistSyncClient {
    async fn replay_create(
        &self,
        request: &ExternalCreateRequest,
    ) -> Result<ExternalTask, CliError> {
        let provider_request = TodoistCreateTaskRequest {
            content: request.title().to_owned(),
            description: non_empty_body(request.body()),
            project_id: self.recovery_project_id(request.provider_target()),
        };
        self.create_task(&provider_request, request.create_key())
            .await
            .map(Into::into)
    }

    fn recovery_project_id(&self, provider_target: &str) -> Option<String> {
        (!self.project_filter().is_empty() || provider_target != TODOIST_ALL_SCOPE)
            .then(|| provider_target.to_owned())
    }
}
