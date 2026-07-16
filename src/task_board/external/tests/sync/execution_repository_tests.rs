use async_trait::async_trait;
use tempfile::tempdir;

use super::super::support::{FakeSyncClient, github_review_request_item};
use crate::errors::CliError;
use crate::task_board::{
    ExternalCreateOutcome, ExternalProvider, ExternalSyncAction, ExternalSyncClient,
    ExternalSyncConflictPolicy, ExternalSyncDirection, ExternalSyncOptions, ExternalTask,
    ExternalTaskRef, TaskBoardItem, TaskBoardStatus, TaskBoardStore, sync_external_tasks,
};

#[tokio::test]
async fn github_create_persists_repository_without_replacing_project_identity() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "local-1".to_owned(),
        "Local issue".to_owned(),
        "Body".to_owned(),
        "2026-07-16T00:00:00Z".to_owned(),
    );
    item.project_id = Some("portfolio-primary".to_owned());
    board
        .create("Local issue", "Body", item)
        .expect("create local task");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(GitHubCreateClient)];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Push,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("create GitHub issue");

    assert_eq!(operations.len(), 1);
    assert!(operations[0].applied);
    let linked = board.get("local-1").expect("load linked task");
    assert_eq!(linked.project_id.as_deref(), Some("portfolio-primary"));
    assert_eq!(linked.execution_repository.as_deref(), Some("owner/repo"));
    let state = linked.external_refs[0]
        .sync_state
        .as_ref()
        .expect("created sync state");
    assert_eq!(state.project_id.as_deref(), Some("owner/repo"));
    assert_eq!(state.updated_at.as_deref(), Some("provider-revision-1"));
}

#[tokio::test]
async fn github_pull_preserves_project_identity_while_backfilling_execution_repository() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = github_review_request_item(
        "github-owner-repo-18",
        "owner/repo#18",
        TaskBoardStatus::Backlog,
    );
    item.project_id = Some("portfolio-primary".to_owned());
    item.execution_repository = None;
    item.external_refs[0]
        .sync_state
        .as_mut()
        .expect("existing sync state")
        .project_id = Some("portfolio-primary".to_owned());
    board
        .create("Review requested", "Please review the pull request.", item)
        .expect("create existing GitHub item");
    let remote = ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, "owner/repo#18")
            .with_url("https://example.test/pull/owner/repo#18"),
        title: "Review requested".to_owned(),
        body: "Please review the pull request.".to_owned(),
        status: TaskBoardStatus::Backlog,
        project_id: Some("owner/repo".to_owned()),
        updated_at: Some("2026-05-14T03:00:00Z".to_owned()),
    };
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::GitHub,
        vec![remote],
    ))];
    let options = ExternalSyncOptions {
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Pull,
        conflict_policy: ExternalSyncConflictPolicy::PreferRemote,
        dry_run: false,
        status: None,
    };

    let operations = sync_external_tasks(&board, options, &clients)
        .await
        .expect("backfill execution repository");

    assert_eq!(operations.len(), 1);
    assert_eq!(operations[0].action, ExternalSyncAction::Pull);
    assert!(operations[0].applied);
    let updated = board
        .get("github-owner-repo-18")
        .expect("load backfilled item");
    assert_eq!(updated.project_id.as_deref(), Some("portfolio-primary"));
    assert_eq!(updated.execution_repository.as_deref(), Some("owner/repo"));
    assert_eq!(
        updated.external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.project_id.as_deref()),
        Some("owner/repo")
    );
    assert!(
        sync_external_tasks(&board, options, &clients)
            .await
            .expect("repeat sync")
            .is_empty()
    );
}

struct GitHubCreateClient;

#[async_trait]
impl ExternalSyncClient for GitHubCreateClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn scope_id(&self) -> String {
        "owner/repo".to_owned()
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        Ok(Vec::new())
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        Ok(ExternalTaskRef::new(
            ExternalProvider::GitHub,
            "owner/repo#17",
        ))
    }

    async fn push_task_with_outcome(
        &self,
        item: &TaskBoardItem,
    ) -> Result<ExternalCreateOutcome, CliError> {
        Ok(ExternalCreateOutcome {
            reference: self.push_task(item).await?,
            provider_revision: Some("provider-revision-1".to_owned()),
            provider_project_id: Some("owner/repo".to_owned()),
        })
    }
}
