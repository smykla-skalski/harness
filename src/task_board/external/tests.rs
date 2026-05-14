use std::sync::Mutex;

use async_trait::async_trait;
use temp_env::with_vars;
use tempfile::tempdir;

use super::*;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::task_board::store::TaskBoardStore;
use crate::task_board::{ExternalRefProvider, build_dispatch_plan};

#[test]
fn env_config_prefers_harness_github_token() {
    let config = with_vars(
        [
            (HARNESS_GITHUB_TOKEN_ENV, Some(" harness-token ")),
            (HARNESS_GITHUB_REPOSITORY_ENV, Some(" owner/repo ")),
            (GITHUB_REPOSITORY_ENV, Some("fallback/repo")),
            (GH_TOKEN_ENV, Some("gh-token")),
            (HARNESS_TODOIST_TOKEN_ENV, Some("todoist-token")),
        ],
        ExternalSyncConfig::from_env,
    );

    assert_eq!(
        config.token_for(ExternalProvider::GitHub),
        Some("harness-token")
    );
    assert_eq!(
        config.token_for(ExternalProvider::Todoist),
        Some("todoist-token")
    );
    assert_eq!(config.github_repository.as_deref(), Some("owner/repo"));
}

#[test]
fn env_config_falls_back_to_gh_token() {
    let config = with_vars(
        [
            (HARNESS_GITHUB_TOKEN_ENV, None::<&str>),
            (HARNESS_GITHUB_REPOSITORY_ENV, None::<&str>),
            (GITHUB_REPOSITORY_ENV, None::<&str>),
            (GH_TOKEN_ENV, Some("gh-token")),
            (HARNESS_TODOIST_TOKEN_ENV, None::<&str>),
        ],
        ExternalSyncConfig::from_env,
    );

    assert_eq!(config.token_for(ExternalProvider::GitHub), Some("gh-token"));
    assert_eq!(config.token_for(ExternalProvider::Todoist), None);
}

#[test]
fn config_debug_redacts_tokens() {
    let config = ExternalSyncConfig {
        github_token: Some("secret".to_owned()),
        github_repository: Some("owner/repo".to_owned()),
        todoist_token: None,
    };

    let debug = format!("{config:?}");
    assert!(debug.contains("<redacted>"));
    assert!(debug.contains("<unset>"));
    assert!(debug.contains("owner/repo"));
    assert!(!debug.contains("secret"));
}

#[test]
fn github_constructor_validates_default_repository() {
    let err = GitHubSyncClient::new_with_repository("token", Some("invalid"))
        .expect_err("invalid repository should fail")
        .message();

    assert!(err.contains("owner/repo"));
}

#[test]
fn external_ref_round_trips_to_core_ref() {
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "issue-7")
        .with_url("https://example.test/7");

    let core = reference.clone().into_core_ref();
    assert_eq!(core.provider, ExternalRefProvider::GitHub);
    assert_eq!(core.external_id, "issue-7");

    let restored = ExternalTaskRef::from(core);
    assert_eq!(restored, reference);
}

#[tokio::test]
async fn fake_client_pulls_tasks_without_network() {
    let client = FakeSyncClient {
        provider: ExternalProvider::Todoist,
        tasks: vec![external_task("remote-1", "Remote task")],
        pushed: Mutex::new(Vec::new()),
    };

    let tasks = client.pull_tasks().await.expect("fake pull should succeed");

    assert_eq!(client.provider(), ExternalProvider::Todoist);
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].title, "Remote task");
}

#[tokio::test]
async fn fake_client_pushes_task_without_network() {
    let mut item = TaskBoardItem::new(
        "task-1".to_owned(),
        "Local task".to_owned(),
        "Body".to_owned(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    item.status = TaskBoardStatus::InProgress;
    let client = FakeSyncClient {
        provider: ExternalProvider::GitHub,
        tasks: Vec::new(),
        pushed: Mutex::new(Vec::new()),
    };

    let reference = client
        .push_task(&item)
        .await
        .expect("fake push should succeed");

    assert_eq!(reference.provider, ExternalProvider::GitHub);
    assert_eq!(reference.external_id, "task-1");
    assert_eq!(
        *client
            .pushed
            .lock()
            .expect("push log should not be poisoned"),
        vec!["task-1"]
    );
}

#[tokio::test]
async fn sync_external_tasks_uses_injected_clients_without_network() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut local = TaskBoardItem::new(
        "local-1".to_owned(),
        "Local task".to_owned(),
        "Body".to_owned(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    local.status = TaskBoardStatus::Todo;
    board
        .create("Local task", "Body", local)
        .expect("create local task");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient {
        provider: ExternalProvider::Todoist,
        tasks: vec![external_task("remote-1", "Remote task")],
        pushed: Mutex::new(Vec::new()),
    })];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Both,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 2);
    assert!(operations.iter().any(|operation| {
        operation.action == ExternalSyncAction::Pull
            && operation.board_item_id.as_deref() == Some("todoist-remote-1")
            && operation.applied
    }));
    assert!(operations.iter().any(|operation| {
        operation.action == ExternalSyncAction::Push
            && operation.board_item_id.as_deref() == Some("local-1")
            && operation.external_id.as_deref() == Some("local-1")
            && operation.applied
    }));
    let pulled = board.get("todoist-remote-1").expect("load pulled task");
    assert_eq!(pulled.title, "Remote task");
    let pushed = board.get("local-1").expect("load pushed task");
    assert!(pushed.external_refs.iter().any(|reference| {
        reference.provider == ExternalRefProvider::Todoist && reference.external_id == "local-1"
    }));
}

#[tokio::test]
async fn sync_external_tasks_dry_run_does_not_write_board() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let local = TaskBoardItem::new(
        "local-1".to_owned(),
        "Local task".to_owned(),
        String::new(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    board
        .create("Local task", "", local)
        .expect("create local task");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient {
        provider: ExternalProvider::Todoist,
        tasks: vec![external_task("remote-2", "Remote task")],
        pushed: Mutex::new(Vec::new()),
    })];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Both,
            dry_run: true,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 2);
    assert!(operations.iter().all(|operation| !operation.applied));
    assert!(operations.iter().any(|operation| {
        operation.action == ExternalSyncAction::Pull
            && operation.board_item_id.as_deref() == Some("todoist-remote-2")
            && operation.external_id.as_deref() == Some("remote-2")
            && operation.dry_run
    }));
    assert!(operations.iter().any(|operation| {
        operation.action == ExternalSyncAction::Push
            && operation.board_item_id.as_deref() == Some("local-1")
            && operation.dry_run
    }));
    assert!(board.get("todoist-remote-2").is_err());
    assert!(
        board
            .get("local-1")
            .expect("local task")
            .external_refs
            .is_empty()
    );
}

#[test]
fn provider_constructors_require_tokens_without_network() {
    let config = ExternalSyncConfig::default();

    let github_error = GitHubSyncClient::from_config(&config)
        .expect_err("missing github token should fail")
        .message();
    let todoist_error = TodoistSyncClient::from_config(&config)
        .expect_err("missing todoist token should fail")
        .message();

    assert!(github_error.contains(HARNESS_GITHUB_TOKEN_ENV));
    assert!(github_error.contains(GH_TOKEN_ENV));
    assert!(todoist_error.contains(HARNESS_TODOIST_TOKEN_ENV));
}

#[test]
fn github_repository_fallback_is_used_only_when_env_is_missing() {
    let from_fallback =
        ExternalSyncConfig::default().with_github_repository_fallback(Some(" owner/repo "));
    let from_env = ExternalSyncConfig {
        github_token: None,
        github_repository: Some("env/repo".to_string()),
        todoist_token: None,
    }
    .with_github_repository_fallback(Some("owner/repo"));

    assert_eq!(from_fallback.github_repository(), Some("owner/repo"));
    assert_eq!(from_env.github_repository(), Some("env/repo"));
}

#[tokio::test]
async fn sync_external_tasks_imports_github_tasks_as_dispatch_ready_items() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient {
        provider: ExternalProvider::GitHub,
        tasks: vec![github_external_task("7", "Remote issue", "owner/repo")],
        pushed: Mutex::new(Vec::new()),
    })];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Pull,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 1);
    let item = board.get("github-7").expect("load imported github task");
    assert_eq!(item.project_id.as_deref(), Some("owner/repo"));
    assert_eq!(
        item.planning.approved_by.as_deref(),
        Some(CONTROL_PLANE_ACTOR_ID)
    );
    assert!(item.planning.approved_at.is_some());
    assert!(
        item.planning
            .summary
            .as_deref()
            .is_some_and(|summary| summary.contains("Remote issue"))
    );
    assert!(item.external_refs.iter().any(|reference| {
        reference.provider == ExternalRefProvider::GitHub && reference.external_id == "7"
    }));
    assert!(build_dispatch_plan(&item).is_ready());
}

struct FakeSyncClient {
    provider: ExternalProvider,
    tasks: Vec<ExternalTask>,
    pushed: Mutex<Vec<String>>,
}

#[async_trait]
impl ExternalSyncClient for FakeSyncClient {
    fn provider(&self) -> ExternalProvider {
        self.provider
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
}

fn external_task(external_id: &str, title: &str) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::Todoist, external_id),
        title: title.to_owned(),
        body: String::new(),
        status: TaskBoardStatus::Todo,
        project_id: None,
        updated_at: None,
    }
}

fn github_external_task(external_id: &str, title: &str, project_id: &str) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, external_id)
            .with_url(format!("https://example.test/issues/{external_id}")),
        title: title.to_owned(),
        body: "Investigate the linked issue.".to_owned(),
        status: TaskBoardStatus::Todo,
        project_id: Some(project_id.to_owned()),
        updated_at: Some("2026-05-14T03:00:00Z".to_string()),
    }
}
