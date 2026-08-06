use super::*;

pub(super) struct ConflictPullClient;

#[async_trait]
impl ExternalSyncClient for ConflictPullClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn scope_id(&self) -> String {
        "acme/widgets".into()
    }

    fn allows_push(&self) -> bool {
        false
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        Ok(vec![ExternalTask {
            reference: ExternalTaskRef::new(ExternalProvider::GitHub, "acme/widgets#17"),
            title: "Remote title".into(),
            body: String::new(),
            status: TaskBoardStatus::Done,
            project_id: Some("acme/widgets".into()),
            updated_at: Some("2026-07-15T10:05:00Z".into()),
            ..ExternalTask::default()
        }])
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        Err(CliErrorKind::workflow_io("pull-only test client").into())
    }
}

pub(super) struct ScopedPullClient {
    scope_id: String,
    result: Result<Vec<ExternalTask>, &'static str>,
}

impl ScopedPullClient {
    pub(super) fn failing(scope_id: &str) -> Self {
        Self {
            scope_id: scope_id.into(),
            result: Err("repository unavailable"),
        }
    }

    pub(super) fn successful(scope_id: &str, task: ExternalTask) -> Self {
        Self {
            scope_id: scope_id.into(),
            result: Ok(vec![task]),
        }
    }

    fn successful_many(scope_id: &str, tasks: Vec<ExternalTask>) -> Self {
        Self {
            scope_id: scope_id.into(),
            result: Ok(tasks),
        }
    }
}

#[async_trait]
impl ExternalSyncClient for ScopedPullClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn scope_id(&self) -> String {
        self.scope_id.clone()
    }

    fn allows_push(&self) -> bool {
        false
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        self.result
            .clone()
            .map_err(|message| CliErrorKind::workflow_io(message).into())
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("pull-only test client")
    }
}

pub(super) fn pull_options() -> ExternalSyncOptions {
    ExternalSyncOptions {
        status: None,
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Pull,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run: false,
    }
}

pub(super) async fn begin_attempt(
    db: &AsyncDaemonDb,
    scope_id: &str,
    now: &str,
) -> crate::task_board::external::ExternalProviderScopeAttempt {
    match db
        .begin_task_board_provider_scope_attempt(ExternalProvider::GitHub, scope_id, now)
        .await
        .expect("begin provider scope attempt")
    {
        ExternalProviderScopeAttemptDecision::Started(attempt) => attempt,
        other => panic!("expected started attempt, got {other:?}"),
    }
}

pub(super) fn external_task(external_id: &str, status: TaskBoardStatus) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, external_id),
        title: "Remote task".into(),
        body: String::new(),
        status,
        project_id: Some("acme/widgets".into()),
        updated_at: Some("2026-07-15T10:05:00Z".into()),
        ..ExternalTask::default()
    }
}

pub(super) fn cyclic_task(external_id: &str, parent_external_id: &str) -> ExternalTask {
    ExternalTask {
        parent_reference: Some(ExternalTaskRef::new(
            ExternalProvider::GitHub,
            parent_external_id,
        )),
        ..external_task(external_id, TaskBoardStatus::Inbox)
    }
}

pub(super) async fn sync_scoped(
    db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
    tasks: Vec<ExternalTask>,
) -> Result<crate::task_board::external::ExternalSyncBatch, CliError> {
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(
        ScopedPullClient::successful_many("acme/widgets", tasks),
    )];
    crate::task_board::external::sync_external_tasks_scoped(db, pull_options(), &clients).await
}

pub(super) fn find_by_external_id<'a>(
    items: &'a [TaskBoardItem],
    external_id: &str,
) -> &'a TaskBoardItem {
    items
        .iter()
        .find(|item| {
            item.external_refs
                .iter()
                .any(|reference| reference.external_id == external_id)
        })
        .unwrap_or_else(|| panic!("no imported item for external id '{external_id}'"))
}

pub(super) fn linked_item(id: &str, status: TaskBoardStatus) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Remote task".into(),
        String::new(),
        "2026-07-15T10:00:00Z".into(),
    );
    item.status = status;
    item.project_id = Some("acme/widgets".into());
    item.execution_repository = Some("acme/widgets".into());
    let mut reference =
        ExternalTaskRef::new(ExternalProvider::GitHub, "acme/widgets#18").into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        title: Some("Remote task".into()),
        body: Some(String::new()),
        status: Some(TaskBoardStatus::Inbox),
        project_id: Some("acme/widgets".into()),
        updated_at: Some("2026-07-15T10:00:00Z".into()),
        synced_at: Some("2026-07-15T10:00:00Z".into()),
        labels: Vec::new(),
    });
    item.external_refs = vec![reference];
    item
}

pub(super) fn conflict(conflict_id: &str, field: &str) -> TaskBoardSyncConflict {
    TaskBoardSyncConflict {
        conflict_id: conflict_id.into(),
        item_id: "task-1".into(),
        provider: ExternalRefProvider::GitHub,
        external_ref: "acme/widgets#17".into(),
        field: field.into(),
        base_value: serde_json::json!("base"),
        local_value: serde_json::json!("local"),
        remote_value: serde_json::json!("remote"),
        item_revision: 1,
        provider_revision: Some("provider-revision-1".into()),
        state: TaskBoardConflictState::Open,
    }
}
