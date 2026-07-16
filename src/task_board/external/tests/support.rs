use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use crate::errors::CliError;
use crate::task_board::{
    ExternalProvider, ExternalRef, ExternalRefProvider, ExternalRefSyncState, ExternalSyncClient,
    ExternalTask, ExternalTaskRef, PlanningState, TaskBoardItem, TaskBoardStatus,
};

pub(super) struct FakeSyncClient {
    provider: ExternalProvider,
    tasks: Vec<ExternalTask>,
    pushed: Mutex<Vec<String>>,
    allows_delete: bool,
    authoritative_review_inbox: bool,
    deleted: Arc<Mutex<Vec<String>>>,
}

impl FakeSyncClient {
    pub(super) fn new(provider: ExternalProvider, tasks: Vec<ExternalTask>) -> Self {
        Self {
            provider,
            tasks,
            pushed: Mutex::new(Vec::new()),
            allows_delete: false,
            authoritative_review_inbox: false,
            deleted: Arc::new(Mutex::new(Vec::new())),
        }
    }

    pub(super) fn with_delete(mut self) -> Self {
        self.allows_delete = true;
        self
    }

    pub(super) fn with_authoritative_review_inbox(mut self) -> Self {
        self.authoritative_review_inbox = true;
        self
    }

    pub(super) fn pushed_ids(&self) -> Vec<String> {
        self.pushed
            .lock()
            .expect("push log should not be poisoned")
            .clone()
    }

    pub(super) fn deleted_handle(&self) -> Arc<Mutex<Vec<String>>> {
        self.deleted.clone()
    }
}

#[async_trait]
impl ExternalSyncClient for FakeSyncClient {
    fn provider(&self) -> ExternalProvider {
        self.provider
    }

    fn allows_delete(&self) -> bool {
        self.allows_delete
    }

    fn authoritative_review_inbox(&self) -> bool {
        self.authoritative_review_inbox
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        Ok(self.tasks.clone())
    }

    async fn push_task(&self, item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        self.pushed
            .lock()
            .expect("push log should not be poisoned")
            .push(item.id.clone());
        Ok(ExternalTaskRef::new(self.provider, item.id.clone()))
    }

    async fn delete_task(
        &self,
        _item: &TaskBoardItem,
        reference: &ExternalTaskRef,
    ) -> Result<(), CliError> {
        self.deleted
            .lock()
            .expect("delete log should not be poisoned")
            .push(reference.external_id.clone());
        Ok(())
    }
}

pub(super) fn external_task(external_id: &str, title: &str) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::Todoist, external_id),
        title: title.to_owned(),
        body: String::new(),
        status: TaskBoardStatus::Backlog,
        project_id: None,
        updated_at: None,
    }
}

pub(super) fn github_external_task(
    external_id: &str,
    title: &str,
    project_id: &str,
) -> ExternalTask {
    github_external_task_with_status(external_id, title, project_id, TaskBoardStatus::Backlog)
}

pub(super) fn github_external_task_with_status(
    external_id: &str,
    title: &str,
    project_id: &str,
    status: TaskBoardStatus,
) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, external_id)
            .with_url(format!("https://example.test/issues/{external_id}")),
        title: title.to_owned(),
        body: "Investigate the linked issue.".to_owned(),
        status,
        project_id: Some(project_id.to_owned()),
        updated_at: Some("2026-05-14T03:00:00Z".to_string()),
    }
}

pub(super) fn github_review_request_item(
    id: &str,
    external_id: &str,
    status: TaskBoardStatus,
) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.to_owned(),
        "Review requested".to_owned(),
        "Please review the pull request.".to_owned(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    item.status = status;
    item.project_id = Some("owner/repo".to_owned());
    item.execution_repository = Some("owner/repo".to_owned());
    item.imported_from_provider = Some(ExternalRefProvider::GitHub);
    item.planning = PlanningState::default();
    item.external_refs = vec![github_review_request_ref(external_id)];
    item
}

fn github_review_request_ref(external_id: &str) -> ExternalRef {
    let mut reference = ExternalTaskRef::new(ExternalProvider::GitHub, external_id)
        .with_url(format!("https://example.test/pull/{external_id}"))
        .into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        title: Some("Review requested".to_owned()),
        body: Some("Please review the pull request.".to_owned()),
        status: Some(TaskBoardStatus::Backlog),
        project_id: Some("owner/repo".to_owned()),
        updated_at: Some("2026-05-14T03:00:00Z".to_owned()),
        synced_at: Some("2026-05-14T03:00:00Z".to_owned()),
    });
    reference
}
