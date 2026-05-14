use std::sync::Mutex;

use async_trait::async_trait;
use temp_env::with_vars;

use super::*;

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
        updated_at: None,
    }
}
