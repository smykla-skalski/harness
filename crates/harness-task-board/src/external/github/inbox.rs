use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;

use crate::external::targeting::github_repository_for_item;
use crate::external::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConfig, ExternalTask, ExternalTaskRef,
    normalize_token,
};
use crate::normalize_repository_slug;
use crate::types::TaskBoardItem;
use harness_github_api::GitHubProtectedClient;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::{
    DEPENDENCY_BOT_AUTHORS, GitHubRepository, assigned_issue_query, dependency_author_query,
    dependency_label_query, graphql, parse_github_repository, review_request_query,
    warn_github_message,
};

mod batch;
mod mapping;

#[derive(Clone)]
pub struct GitHubInboxSyncClient {
    client: GitHubProtectedClient,
    repositories: Vec<GitHubRepository>,
    import_labels: Vec<String>,
    include_review_requests: bool,
    /// Whether the most recent pull observed every configured query. A pull
    /// that skipped a failed query is short of the live inbox, so it must not
    /// act authoritative and close a ticket whose pull request went missing
    /// only behind that failure. Callers build a fresh client per sync, so the
    /// persisted-scope role (`ExternalProviderScopeIdentity::for_client`, read
    /// before the pull) always reflects the `true` default while the close path
    /// reads this instance's own post-pull value.
    last_pull_complete: Arc<AtomicBool>,
    batch: Option<Arc<batch::InboxBatch>>,
}

impl GitHubInboxSyncClient {
    /// Build a GitHub inbox client from token and repositories.
    ///
    /// # Errors
    /// Returns an error when the token is empty, repositories are invalid, or
    /// the SDK client cannot be built.
    pub fn new(token: impl Into<String>, repositories: &[String]) -> Result<Self, CliError> {
        Self::new_with_labels(token, repositories, &[])
    }

    /// Build a GitHub inbox client with an optional label filter applied to issue
    /// searches.
    ///
    /// # Errors
    /// Returns an error when the token is empty, repositories are invalid, or
    /// the SDK client cannot be built.
    pub fn new_with_labels(
        token: impl Into<String>,
        repositories: &[String],
        import_labels: &[String],
    ) -> Result<Self, CliError> {
        let token = normalize_token(ExternalProvider::GitHub, token)?;
        let client = GitHubProtectedClient::new(&token)?;
        let repositories = repositories
            .iter()
            .map(String::as_str)
            .map(parse_github_repository)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self {
            client,
            repositories,
            import_labels: import_labels.to_vec(),
            include_review_requests: true,
            last_pull_complete: Arc::new(AtomicBool::new(true)),
            batch: None,
        })
    }

    /// Build a GitHub inbox client from external sync config.
    ///
    /// # Errors
    /// Returns an error when no GitHub token is configured or repositories are invalid.
    pub fn from_config(config: &ExternalSyncConfig) -> Result<Self, CliError> {
        Self::new_with_labels(
            config.require_token(ExternalProvider::GitHub)?,
            config.github_inbox_repositories(),
            config.github_import_labels(),
        )
    }

    /// Build a GitHub inbox client that only imports assigned tasks.
    ///
    /// # Errors
    /// Returns an error when no GitHub token is configured or repositories are invalid.
    pub fn from_config_assigned_only(config: &ExternalSyncConfig) -> Result<Self, CliError> {
        let mut client = Self::from_config(config)?;
        client.include_review_requests = false;
        Ok(client)
    }

    /// Build one pull-only client per configured repository while sharing one
    /// aliased GraphQL batch across the whole set.
    ///
    /// # Errors
    /// Returns an error when no GitHub token is configured or a repository is invalid.
    pub fn assigned_only_scoped_from_config(
        config: &ExternalSyncConfig,
        fresh: bool,
    ) -> Result<Vec<Self>, CliError> {
        Self::scoped_from_config(config, fresh, false)
    }

    /// Build one pull-only client per configured repository while sharing one
    /// aliased GraphQL batch across assigned, dependency, and optional review
    /// searches.
    ///
    /// # Errors
    /// Returns an error when no GitHub token is configured or a repository is invalid.
    pub fn scoped_from_config(
        config: &ExternalSyncConfig,
        fresh: bool,
        include_review_requests: bool,
    ) -> Result<Vec<Self>, CliError> {
        let token = normalize_token(
            ExternalProvider::GitHub,
            config.require_token(ExternalProvider::GitHub)?,
        )?;
        let client = GitHubProtectedClient::new(&token)?;
        let repositories = config
            .github_inbox_repositories()
            .iter()
            .map(String::as_str)
            .map(parse_github_repository)
            .collect::<Result<Vec<_>, _>>()?;
        let batch = Arc::new(batch::InboxBatch::new(
            client.clone(),
            repositories.clone(),
            config.github_import_labels().to_vec(),
            fresh,
            include_review_requests,
        ));
        Ok(repositories
            .into_iter()
            .map(|repository| Self {
                client: client.clone(),
                repositories: vec![repository],
                import_labels: config.github_import_labels().to_vec(),
                include_review_requests,
                last_pull_complete: Arc::new(AtomicBool::new(true)),
                batch: Some(Arc::clone(&batch)),
            })
            .collect())
    }

    fn mark_pull_complete(&self, complete: bool) {
        self.last_pull_complete.store(complete, Ordering::Release);
    }

    async fn current_user_login(&self) -> Result<String, CliError> {
        self.client.viewer_login().await
    }

    async fn search(
        &self,
        repository: &GitHubRepository,
        kind: GitHubInboxSearchKind,
        login: &str,
    ) -> Result<Vec<graphql::GitHubSearchIssuePullRequestItem>, CliError> {
        let query = kind.query(repository, login);
        graphql::search_issue_pull_requests(&self.client, &query, &kind.context(repository)).await
    }
}

impl fmt::Debug for GitHubInboxSyncClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("GitHubInboxSyncClient")
            .field("provider", &ExternalProvider::GitHub)
            .field("repositories", &self.repositories)
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl ExternalSyncClient for GitHubInboxSyncClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn scope_id(&self) -> String {
        self.repositories.first().map_or_else(
            || "inbox".into(),
            |repository| {
                normalize_repository_slug(Some(&repository.slug()))
                    .expect("parsed GitHub repository must have a normalized slug")
            },
        )
    }

    fn scope_for_item(&self, item: &TaskBoardItem) -> String {
        normalize_repository_slug(github_repository_for_item(item))
            .unwrap_or_else(|| self.scope_id())
    }

    fn allows_push(&self) -> bool {
        false
    }

    fn authoritative_review_inbox(&self) -> bool {
        self.include_review_requests && self.last_pull_complete.load(Ordering::Acquire)
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        if self.repositories.is_empty() {
            self.mark_pull_complete(true);
            return Ok(Vec::new());
        }
        if let Some(batch) = &self.batch {
            let result = batch.pull_repository(&self.repositories[0]).await;
            match result {
                Ok((tasks, complete)) => {
                    self.mark_pull_complete(complete);
                    return Ok(tasks);
                }
                Err(error) => {
                    self.mark_pull_complete(false);
                    return Err(error);
                }
            }
        }
        let login = self.current_user_login().await?;
        let mut tasks = Vec::new();
        let mut failures = Vec::new();
        let mut pulled_repository_count = 0_usize;
        for repository in &self.repositories {
            let assigned_tasks = match self.assigned_issue_tasks(repository, login.as_str()).await {
                Ok(assigned_tasks) => assigned_tasks,
                Err(error) => {
                    record_repository_failure(
                        &mut failures,
                        repository,
                        "assigned issue search",
                        &error,
                    );
                    continue;
                }
            };
            pulled_repository_count += 1;
            tasks.extend(assigned_tasks);

            if self.include_review_requests {
                match self.review_request_tasks(repository, login.as_str()).await {
                    Ok(review_tasks) => tasks.extend(review_tasks),
                    Err(error) => record_repository_failure(
                        &mut failures,
                        repository,
                        "review request search",
                        &error,
                    ),
                }
            }

            // Dependency-update pull requests are assignment-independent and
            // are the only source for a dependency-only ticket, so discover
            // them even when this client imports assigned work alone.
            match self.dependency_update_tasks(repository).await {
                Ok(dependency_tasks) => tasks.extend(dependency_tasks),
                Err(error) => record_repository_failure(
                    &mut failures,
                    repository,
                    "dependency update search",
                    &error,
                ),
            }
        }
        if pulled_repository_count == 0 && !failures.is_empty() {
            self.mark_pull_complete(false);
            return Err(all_inbox_repositories_failed(failures));
        }
        self.mark_pull_complete(failures.is_empty());
        // A pull request can match both the review-request and a dependency
        // search, so fold those into one ticket that carries both intents.
        Ok(mapping::union_pull_request_intents(tasks))
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        Err(CliErrorKind::workflow_io(
            "task-board github inbox sync is pull-only and cannot create remote items",
        )
        .into())
    }
}

impl GitHubInboxSyncClient {
    async fn assigned_issue_tasks(
        &self,
        repository: &GitHubRepository,
        login: &str,
    ) -> Result<Vec<ExternalTask>, CliError> {
        let items = self
            .search(repository, GitHubInboxSearchKind::AssignedIssues, login)
            .await?;
        Ok(mapping::assigned_issue_tasks(
            repository,
            &self.import_labels,
            items,
            true,
        ))
    }

    async fn review_request_tasks(
        &self,
        repository: &GitHubRepository,
        login: &str,
    ) -> Result<Vec<ExternalTask>, CliError> {
        let items = self
            .search(repository, GitHubInboxSearchKind::ReviewRequests, login)
            .await?;
        Ok(mapping::review_request_tasks(
            repository,
            &self.import_labels,
            items,
            true,
        ))
    }

    async fn dependency_update_tasks(
        &self,
        repository: &GitHubRepository,
    ) -> Result<Vec<ExternalTask>, CliError> {
        let project_id = repository.slug();
        let context = format!("searching dependency pull requests in {project_id}");
        let mut items = Vec::new();
        // Each bot is a separate query - GitHub issue search ANDs repeated
        // `author:` qualifiers, so one combined clause would never match.
        for author in DEPENDENCY_BOT_AUTHORS {
            let query = dependency_author_query(repository, author);
            items
                .extend(graphql::search_issue_pull_requests(&self.client, &query, &context).await?);
        }
        items.extend(
            graphql::search_issue_pull_requests(
                &self.client,
                &dependency_label_query(repository),
                &context,
            )
            .await?,
        );
        Ok(mapping::dependency_update_tasks(
            repository,
            &self.import_labels,
            items,
            true,
        ))
    }
}

fn record_repository_failure(
    failures: &mut Vec<String>,
    repository: &GitHubRepository,
    operation: &str,
    error: &CliError,
) {
    let failure = format!(
        "{} {operation} failed: {}",
        repository.slug(),
        error.message()
    );
    warn_github_message(&format!("skipping GitHub inbox repository {failure}"));
    failures.push(failure);
}

fn all_inbox_repositories_failed(failures: Vec<String>) -> CliError {
    let details = failures
        .into_iter()
        .map(|failure| format!("- {failure}"))
        .collect::<Vec<_>>()
        .join("\n");
    CliErrorKind::workflow_io("task-board github inbox sync failed for all configured repositories")
        .with_details(details)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GitHubInboxSearchKind {
    AssignedIssues,
    ReviewRequests,
}

impl GitHubInboxSearchKind {
    fn query(self, repository: &GitHubRepository, login: &str) -> String {
        match self {
            Self::AssignedIssues => assigned_issue_query(repository, login),
            Self::ReviewRequests => review_request_query(repository, login),
        }
    }

    fn context(self, repository: &GitHubRepository) -> String {
        let slug = repository.slug();
        match self {
            Self::AssignedIssues => format!("searching assigned issues in {slug}"),
            Self::ReviewRequests => format!("searching review requests in {slug}"),
        }
    }
}

#[cfg(test)]
mod tests;
