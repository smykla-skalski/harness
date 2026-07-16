use std::collections::BTreeMap;
use std::fmt;

use async_trait::async_trait;
use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::{GitHubProtectedClient, retry_stable_read};
use crate::task_board::normalize_repository_slug;
use crate::task_board::types::{TaskBoardItem, TaskBoardStatus};

use super::targeting::github_repository_for_item;
use super::{
    ExternalCreateOutcome, ExternalCreateRecoveryClient, ExternalProvider,
    ExternalProviderCapabilities, ExternalSyncClient, ExternalSyncConfig, ExternalSyncField,
    ExternalTask, ExternalTaskRef, ExternalTaskUpdate, ExternalUpdateOutcome,
    GITHUB_REPOSITORY_ENV, HARNESS_GITHUB_REPOSITORY_ENV, non_empty_body, normalize_token,
};

mod create_marker;
mod create_recovery;
mod errors;
mod graphql;
mod inbox;
mod review_projection;
#[cfg(test)]
mod test_support;
mod write;

use errors::warn_github_message;
pub use inbox::GitHubInboxSyncClient;
pub(crate) use review_projection::{
    imported_review_references_from_items, reconcile_review_item_from_snapshots,
    reconciled_external_status,
};
#[derive(Clone)]
pub struct GitHubSyncClient {
    client: GitHubProtectedClient,
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
        let client = GitHubProtectedClient::new(&token)?;
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
    pub(crate) const fn protected(&self) -> &GitHubProtectedClient {
        &self.client
    }

    fn repository_for(&self, item: Option<&TaskBoardItem>) -> Result<GitHubRepository, CliError> {
        let candidate = item
            .and_then(github_repository_for_item)
            .map(parse_github_repository)
            .transpose()?;
        candidate
            .or_else(|| self.repository.clone())
            .ok_or_else(missing_github_repository_error)
    }

    async fn pull_tasks_at_revision(&self) -> Result<Vec<ExternalTask>, CliError> {
        let repository = self.repository_for(None)?;
        let project_id = repository.slug();
        let login = self.protected().viewer_login().await?;
        let mut tasks = BTreeMap::new();
        for query in graphql::personal_issue_queries(&repository, login.as_str()) {
            let context = format!("searching task-board issues in {}", repository.slug());
            let issues =
                graphql::search_issue_pull_requests(self.protected(), &query, &context).await?;
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

    #[allow(
        private_interfaces,
        reason = "provider-create recovery is intentionally crate-private"
    )]
    fn external_create_recovery(&self) -> Option<&dyn ExternalCreateRecoveryClient> {
        Some(self)
    }

    fn scope_id(&self) -> String {
        self.repository.as_ref().map_or_else(
            || "linked".into(),
            |repository| {
                normalize_repository_slug(Some(&repository.slug()))
                    .expect("parsed GitHub repository must have a normalized slug")
            },
        )
    }

    fn scope_for_item(&self, item: &TaskBoardItem) -> String {
        if self.repository.is_none() {
            return self.scope_id();
        }
        normalize_repository_slug(github_repository_for_item(item))
            .unwrap_or_else(|| self.scope_id())
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
        retry_stable_read("task_board.github.pull_tasks", |_| {
            self.pull_tasks_at_revision()
        })
        .await
        .map(|(tasks, _)| tasks)
    }

    async fn push_task(&self, item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        Ok(self.push_task_with_outcome(item).await?.reference)
    }

    async fn push_task_with_outcome(
        &self,
        item: &TaskBoardItem,
    ) -> Result<ExternalCreateOutcome, CliError> {
        let repository = self.repository_for(Some(item))?;
        let issue = self.create_issue(&repository, item).await?;
        Ok(created_issue_outcome(&repository, issue))
    }

    async fn update_task(
        &self,
        item: &TaskBoardItem,
        reference: &ExternalTaskRef,
        update: ExternalTaskUpdate,
    ) -> Result<ExternalUpdateOutcome, CliError> {
        let repository = self.repository_for(Some(item))?;
        let issue_number = parse_issue_number(&reference.external_id)?;
        if let Some(precondition) = update.precondition_updated_at.as_deref() {
            // GitHub does not document conditional unsafe requests for issue PATCH.
            // Independent uncached GraphQL and REST reads are the strongest
            // available preflight and return the full snapshot on mismatch.
            let observed_revision =
                graphql::issue_updated_at(self.protected(), &repository, issue_number).await?;
            let current = self.fetch_issue(&repository, issue_number).await?;
            if observed_revision != precondition
                || current.updated_at.as_deref() != Some(precondition)
            {
                return Ok(ExternalUpdateOutcome::PreconditionFailed {
                    current: current.into_external_task(&repository),
                });
            }
        }
        let mut body = serde_json::Map::new();
        if update.changed_fields.contains(&ExternalSyncField::Title) {
            body.insert("title".into(), json!(item.title));
        }
        if update.changed_fields.contains(&ExternalSyncField::Body) {
            body.insert("body".into(), json!(item.body));
        }
        if update.changed_fields.contains(&ExternalSyncField::Status) {
            body.insert("state".into(), json!(github_issue_state(item.status)));
        }
        let issue = self
            .patch_issue(&repository, issue_number, serde_json::Value::Object(body))
            .await?;
        Ok(ExternalUpdateOutcome::Applied {
            reference: ExternalTaskRef::new(
                ExternalProvider::GitHub,
                github_external_id(&repository, issue.number),
            )
            .with_url(issue.html_url),
            provider_revision: issue.updated_at,
        })
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
        self.patch_issue(&repository, issue_number, json!({ "state": "closed" }))
            .await?;
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

fn created_issue_outcome(
    repository: &GitHubRepository,
    issue: write::GitHubIssueResponse,
) -> ExternalCreateOutcome {
    ExternalCreateOutcome {
        reference: ExternalTaskRef::new(
            ExternalProvider::GitHub,
            github_external_id(repository, issue.number),
        )
        .with_url(issue.html_url),
        provider_revision: issue.updated_at,
        provider_project_id: Some(repository.slug()),
    }
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
         {GITHUB_REPOSITORY_ENV}, or item execution_repository as owner/repo"
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
        TaskBoardStatus::Backlog
    }
}

fn github_issue_state(status: TaskBoardStatus) -> &'static str {
    match status {
        TaskBoardStatus::Done => "closed",
        _ => "open",
    }
}

fn github_inbox_issue_status(state: &str) -> TaskBoardStatus {
    if state.eq_ignore_ascii_case("closed") {
        TaskBoardStatus::Done
    } else {
        TaskBoardStatus::Backlog
    }
}

fn github_external_id(repository: &GitHubRepository, issue_number: u64) -> String {
    format!("{}#{issue_number}", repository.slug())
}

// GitHub has no `state:all` qualifier. Repeating the state qualifier matches either state,
// so one query explicitly returns open and closed issues for remote closure reconciliation.
fn assigned_issue_query(repository: &GitHubRepository, login: &str) -> String {
    format!(
        "repo:{} is:issue assignee:{login} state:open state:closed",
        repository.slug()
    )
}

fn author_issue_query(repository: &GitHubRepository, login: &str) -> String {
    format!(
        "repo:{} is:issue author:{login} state:open state:closed",
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

#[cfg(test)]
mod status_tests {
    use super::*;

    #[test]
    fn github_issue_search_status_maps_open_to_backlog_and_closed_to_done() {
        assert_eq!(github_issue_search_status("OPEN"), TaskBoardStatus::Backlog);
        assert_eq!(github_issue_search_status("closed"), TaskBoardStatus::Done);
    }
}
