use std::collections::BTreeMap;
use std::fmt;
use std::sync::OnceLock;

use async_trait::async_trait;
use octocrab::models::IssueState;
use rustls::crypto::ring::default_provider;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::types::{TaskBoardItem, TaskBoardStatus};

use super::{
    ExternalProvider, ExternalProviderCapabilities, ExternalSyncClient, ExternalSyncConfig,
    ExternalSyncField, ExternalTask, ExternalTaskRef, ExternalTaskUpdate, ExternalUpdateOutcome,
    GITHUB_REPOSITORY_ENV, HARNESS_GITHUB_REPOSITORY_ENV, non_empty_body, normalize_token,
};

static RUSTLS_PROVIDER: OnceLock<()> = OnceLock::new();

mod errors;
mod graphql;
mod inbox;

use errors::{github_client_error, github_sync_error_with_context, warn_github_message};
pub use inbox::GitHubInboxSyncClient;

#[derive(Clone)]
pub struct GitHubSyncClient {
    client: octocrab::Octocrab,
    repository: Option<GitHubRepository>,
    pull_enabled: bool,
    import_labels: Vec<String>,
}

impl GitHubSyncClient {
    /// Build a GitHub client from a token using the native GitHub SDK.
    ///
    /// # Errors
    /// Returns an error when the token is empty or the SDK client cannot be built.
    pub fn new(token: impl Into<String>) -> Result<Self, CliError> {
        Self::new_with_repository(token, None)
    }

    /// Build a GitHub client with an optional default repository.
    ///
    /// # Errors
    /// Returns an error when token or repository values are invalid.
    pub fn new_with_repository(
        token: impl Into<String>,
        repository: Option<&str>,
    ) -> Result<Self, CliError> {
        Self::new_with_repository_mode(token, repository, repository.is_some())
    }

    /// Build a GitHub client with explicit pull behavior.
    ///
    /// # Errors
    /// Returns an error when token or repository values are invalid.
    pub fn new_with_repository_mode(
        token: impl Into<String>,
        repository: Option<&str>,
        pull_enabled: bool,
    ) -> Result<Self, CliError> {
        let token = normalize_token(ExternalProvider::GitHub, token)?;
        let repository = repository.map(parse_github_repository).transpose()?;
        ensure_rustls_provider();
        let client = octocrab::Octocrab::builder()
            .personal_token(token)
            .build()
            .map_err(github_client_error)?;
        Ok(Self {
            client,
            repository,
            pull_enabled,
            import_labels: Vec::new(),
        })
    }

    /// Build a GitHub client from external sync config.
    ///
    /// # Errors
    /// Returns an error when no GitHub token is configured or the SDK client
    /// cannot be built.
    pub fn from_config(config: &ExternalSyncConfig) -> Result<Self, CliError> {
        Self::from_config_with_pull(config, config.github_repository().is_some())
    }

    /// Build a GitHub client from external sync config with explicit pull behavior.
    ///
    /// # Errors
    /// Returns an error when no GitHub token is configured or the SDK client
    /// cannot be built.
    pub fn from_config_with_pull(
        config: &ExternalSyncConfig,
        pull_enabled: bool,
    ) -> Result<Self, CliError> {
        let mut client = Self::new_with_repository_mode(
            config.require_token(ExternalProvider::GitHub)?,
            config.github_repository.as_deref(),
            pull_enabled,
        )?;
        client.import_labels = config.github_import_labels().to_vec();
        Ok(client)
    }

    #[must_use]
    pub const fn octocrab(&self) -> &octocrab::Octocrab {
        &self.client
    }

    fn repository_for(&self, item: Option<&TaskBoardItem>) -> Result<GitHubRepository, CliError> {
        let candidate = item
            .and_then(|item| item.project_id.as_deref())
            .map(parse_github_repository)
            .transpose()?;
        candidate
            .or_else(|| self.repository.clone())
            .ok_or_else(missing_github_repository_error)
    }
}

impl fmt::Debug for GitHubSyncClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("GitHubSyncClient")
            .field("provider", &ExternalProvider::GitHub)
            .field("pull_enabled", &self.pull_enabled)
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl ExternalSyncClient for GitHubSyncClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn allows_pull(&self) -> bool {
        self.pull_enabled
    }

    fn capabilities(&self) -> ExternalProviderCapabilities {
        ExternalProviderCapabilities::with_update_fields([
            ExternalSyncField::Title,
            ExternalSyncField::Body,
            ExternalSyncField::Status,
        ])
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        if !self.pull_enabled {
            return Ok(Vec::new());
        }
        let repository = self.repository_for(None)?;
        let project_id = repository.slug();
        let login = graphql::current_user_login(self.octocrab()).await?;
        let mut tasks = BTreeMap::new();
        for query in graphql::personal_issue_queries(&repository, login.as_str()) {
            let context = format!("searching task-board issues in {}", repository.slug());
            let issues =
                graphql::search_issue_pull_requests(self.octocrab(), &query, &context).await?;
            tasks.extend(
                issues
                    .into_iter()
                    .filter(|issue| {
                        search_label_matches_filter(&issue.label_names(), &self.import_labels)
                    })
                    .map(|issue| {
                        let number = issue.number;
                        (
                            number,
                            ExternalTask {
                                reference: ExternalTaskRef::new(
                                    ExternalProvider::GitHub,
                                    github_external_id(&repository, number),
                                )
                                .with_url(issue.url),
                                title: issue.title,
                                body: issue.body.unwrap_or_default(),
                                status: github_issue_search_status(issue.state.as_str()),
                                project_id: Some(project_id.clone()),
                                updated_at: Some(issue.updated_at),
                            },
                        )
                    }),
            );
        }
        Ok(tasks.into_values().collect())
    }

    async fn push_task(&self, item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        let repository = self.repository_for(Some(item))?;
        let issues = self
            .octocrab()
            .issues(repository.owner.as_str(), repository.repo.as_str());
        let mut request = issues.create(&item.title);
        if let Some(body) = non_empty_body(&item.body) {
            request = request.body(body);
        }
        let issue = request.send().await.map_err(|error| {
            github_sync_error_with_context(
                format!("creating issue in {}", repository.slug()),
                error,
            )
        })?;
        Ok(ExternalTaskRef::new(
            ExternalProvider::GitHub,
            github_external_id(&repository, issue.number),
        )
        .with_url(issue.html_url.to_string()))
    }

    async fn update_task(
        &self,
        item: &TaskBoardItem,
        reference: &ExternalTaskRef,
        update: ExternalTaskUpdate,
    ) -> Result<ExternalUpdateOutcome, CliError> {
        let repository = self.repository_for(Some(item))?;
        let issue_number = parse_issue_number(&reference.external_id)?;
        let issues = self
            .octocrab()
            .issues(repository.owner.as_str(), repository.repo.as_str());
        if let Some(precondition) = update.precondition_updated_at.as_deref() {
            let current_updated_at =
                graphql::issue_updated_at(self.octocrab(), &repository, issue_number).await?;
            if current_updated_at != precondition {
                return Ok(ExternalUpdateOutcome::PreconditionFailed);
            }
        }
        let mut request = issues.update(issue_number);
        if update.changed_fields.contains(&ExternalSyncField::Title) {
            request = request.title(&item.title);
        }
        if update.changed_fields.contains(&ExternalSyncField::Body) {
            request = request.body(&item.body);
        }
        if update.changed_fields.contains(&ExternalSyncField::Status) {
            request = request.state(github_issue_state(item.status));
        }
        let issue = request.send().await.map_err(|error| {
            github_sync_error_with_context(
                format!("updating issue {issue_number} in {}", repository.slug()),
                error,
            )
        })?;
        Ok(ExternalUpdateOutcome::Applied(
            ExternalTaskRef::new(
                ExternalProvider::GitHub,
                github_external_id(&repository, issue.number),
            )
            .with_url(issue.html_url.to_string()),
        ))
    }

    fn allows_delete(&self) -> bool {
        true
    }

    async fn delete_task(
        &self,
        item: &TaskBoardItem,
        reference: &ExternalTaskRef,
    ) -> Result<(), CliError> {
        let repository = self.repository_for(Some(item))?;
        let issue_number = parse_issue_number(&reference.external_id)?;
        let issues = self
            .octocrab()
            .issues(repository.owner.as_str(), repository.repo.as_str());
        issues
            .update(issue_number)
            .state(IssueState::Closed)
            .send()
            .await
            .map_err(|error| {
                github_sync_error_with_context(
                    format!("closing issue {issue_number} in {}", repository.slug()),
                    error,
                )
            })?;
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct GitHubRepository {
    owner: String,
    repo: String,
}

impl GitHubRepository {
    fn slug(&self) -> String {
        format!("{}/{}", self.owner, self.repo)
    }
}

fn ensure_rustls_provider() {
    RUSTLS_PROVIDER.get_or_init(|| {
        let _ = default_provider().install_default();
    });
}

fn parse_github_repository(value: &str) -> Result<GitHubRepository, CliError> {
    let mut parts = value.split('/');
    let owner = parts.next().unwrap_or_default().trim();
    let repo = parts.next().unwrap_or_default().trim();
    if owner.is_empty() || repo.is_empty() || parts.next().is_some() {
        return Err(CliErrorKind::workflow_io(format!(
            "task-board github repository must use owner/repo, got '{value}'"
        ))
        .into());
    }
    Ok(GitHubRepository {
        owner: owner.to_owned(),
        repo: repo.to_owned(),
    })
}

fn missing_github_repository_error() -> CliError {
    CliErrorKind::workflow_io(format!(
        "task-board github repository missing; set {HARNESS_GITHUB_REPOSITORY_ENV}, \
         {GITHUB_REPOSITORY_ENV}, or item project_id as owner/repo"
    ))
    .into()
}

fn parse_issue_number(value: &str) -> Result<u64, CliError> {
    value
        .rsplit_once('#')
        .map_or(value, |(_, issue_number)| issue_number)
        .parse::<u64>()
        .map_err(|error| {
            CliError::new(CliErrorKind::workflow_parse(format!(
                "task-board github issue number must be numeric, got '{value}'"
            )))
            .with_source(error)
        })
}

fn github_issue_search_status(state: &str) -> TaskBoardStatus {
    if state.eq_ignore_ascii_case("closed") {
        TaskBoardStatus::Done
    } else {
        TaskBoardStatus::Todo
    }
}

fn github_issue_state(status: TaskBoardStatus) -> IssueState {
    match status {
        TaskBoardStatus::Done => IssueState::Closed,
        _ => IssueState::Open,
    }
}

fn github_inbox_issue_status(state: &str) -> TaskBoardStatus {
    if state.eq_ignore_ascii_case("closed") {
        TaskBoardStatus::Done
    } else {
        TaskBoardStatus::NeedsYou
    }
}

fn github_external_id(repository: &GitHubRepository, issue_number: u64) -> String {
    format!("{}#{issue_number}", repository.slug())
}

fn assigned_issue_query(repository: &GitHubRepository, login: &str) -> String {
    format!(
        "repo:{} is:issue assignee:{login} state:all",
        repository.slug()
    )
}

fn author_issue_query(repository: &GitHubRepository, login: &str) -> String {
    format!(
        "repo:{} is:issue author:{login} state:all",
        repository.slug()
    )
}

fn review_request_query(repository: &GitHubRepository, login: &str) -> String {
    format!(
        "repo:{} is:pr review-requested:{login} state:open",
        repository.slug()
    )
}

pub(super) fn search_label_matches_filter(
    item_labels: &[String],
    import_labels: &[String],
) -> bool {
    if import_labels.is_empty() {
        return true;
    }
    item_labels.iter().any(|name| {
        import_labels
            .iter()
            .any(|wanted| name.eq_ignore_ascii_case(wanted.trim()))
    })
}
