use std::sync::OnceLock;
use std::{env, fmt};

use async_trait::async_trait;
use clap::ValueEnum;
use octocrab::params::State;
use rustls::crypto::ring::default_provider;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::types::{ExternalRef, ExternalRefProvider, TaskBoardItem, TaskBoardStatus};

mod sync;
mod todoist;

pub use sync::{
    ExternalSyncAction, ExternalSyncDirection, ExternalSyncOperation, ExternalSyncOptions,
    configured_sync_clients, sync_external_tasks,
};
pub use todoist::TodoistSyncClient;

pub const HARNESS_GITHUB_TOKEN_ENV: &str = "HARNESS_GITHUB_TOKEN";
pub const GH_TOKEN_ENV: &str = "GH_TOKEN";
pub const HARNESS_TODOIST_TOKEN_ENV: &str = "HARNESS_TODOIST_TOKEN";
pub const HARNESS_GITHUB_REPOSITORY_ENV: &str = "HARNESS_GITHUB_REPOSITORY";
pub const GITHUB_REPOSITORY_ENV: &str = "GITHUB_REPOSITORY";
static RUSTLS_PROVIDER: OnceLock<()> = OnceLock::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ExternalProvider {
    GitHub,
    Todoist,
}

impl ExternalProvider {
    #[must_use]
    pub const fn token_env_names(self) -> &'static [&'static str] {
        match self {
            Self::GitHub => &[HARNESS_GITHUB_TOKEN_ENV, GH_TOKEN_ENV],
            Self::Todoist => &[HARNESS_TODOIST_TOKEN_ENV],
        }
    }
}

impl fmt::Display for ExternalProvider {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::GitHub => formatter.write_str("github"),
            Self::Todoist => formatter.write_str("todoist"),
        }
    }
}

impl From<ExternalRefProvider> for ExternalProvider {
    fn from(provider: ExternalRefProvider) -> Self {
        match provider {
            ExternalRefProvider::GitHub => Self::GitHub,
            ExternalRefProvider::Todoist => Self::Todoist,
        }
    }
}

impl From<ExternalProvider> for ExternalRefProvider {
    fn from(provider: ExternalProvider) -> Self {
        match provider {
            ExternalProvider::GitHub => Self::GitHub,
            ExternalProvider::Todoist => Self::Todoist,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalTaskRef {
    pub provider: ExternalProvider,
    pub external_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

impl ExternalTaskRef {
    #[must_use]
    pub fn new(provider: ExternalProvider, external_id: impl Into<String>) -> Self {
        Self {
            provider,
            external_id: external_id.into(),
            url: None,
        }
    }

    #[must_use]
    pub fn with_url(mut self, url: impl Into<String>) -> Self {
        self.url = Some(url.into());
        self
    }

    #[must_use]
    pub fn into_core_ref(self) -> ExternalRef {
        ExternalRef {
            provider: self.provider.into(),
            external_id: self.external_id,
            url: self.url,
        }
    }
}

impl From<ExternalRef> for ExternalTaskRef {
    fn from(reference: ExternalRef) -> Self {
        Self {
            provider: reference.provider.into(),
            external_id: reference.external_id,
            url: reference.url,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalTask {
    pub reference: ExternalTaskRef,
    pub title: String,
    #[serde(default)]
    pub body: String,
    pub status: TaskBoardStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
}

#[derive(Clone, Default, PartialEq, Eq)]
pub struct ExternalSyncConfig {
    pub github_token: Option<String>,
    pub github_repository: Option<String>,
    pub todoist_token: Option<String>,
}

impl ExternalSyncConfig {
    #[must_use]
    pub fn from_env() -> Self {
        Self {
            github_token: first_present_env(&[HARNESS_GITHUB_TOKEN_ENV, GH_TOKEN_ENV]),
            github_repository: first_present_env(&[
                HARNESS_GITHUB_REPOSITORY_ENV,
                GITHUB_REPOSITORY_ENV,
            ]),
            todoist_token: first_present_env(&[HARNESS_TODOIST_TOKEN_ENV]),
        }
    }

    #[must_use]
    pub fn token_for(&self, provider: ExternalProvider) -> Option<&str> {
        match provider {
            ExternalProvider::GitHub => self.github_token.as_deref(),
            ExternalProvider::Todoist => self.todoist_token.as_deref(),
        }
    }

    #[must_use]
    pub fn github_repository(&self) -> Option<&str> {
        self.github_repository
            .as_deref()
            .map(str::trim)
            .filter(|repository| !repository.is_empty())
    }

    #[must_use]
    pub fn with_github_token_override(mut self, token: Option<&str>) -> Self {
        self.github_token = token
            .map(str::trim)
            .filter(|token| !token.is_empty())
            .map(ToOwned::to_owned);
        self
    }

    #[must_use]
    pub fn with_todoist_token_override(mut self, token: Option<&str>) -> Self {
        self.todoist_token = token
            .map(str::trim)
            .filter(|token| !token.is_empty())
            .map(ToOwned::to_owned);
        self
    }

    #[must_use]
    pub fn with_github_repository_override(mut self, repository: Option<&str>) -> Self {
        self.github_repository = repository
            .map(str::trim)
            .filter(|repository| !repository.is_empty())
            .map(ToOwned::to_owned);
        self
    }

    #[must_use]
    pub fn with_github_repository_fallback(mut self, repository: Option<&str>) -> Self {
        if self.github_repository().is_none() {
            self.github_repository = repository
                .map(str::trim)
                .filter(|repository| !repository.is_empty())
                .map(ToOwned::to_owned);
        }
        self
    }

    /// Return the configured token for a provider.
    ///
    /// # Errors
    /// Returns an error when the provider token is missing or empty.
    pub fn require_token(&self, provider: ExternalProvider) -> Result<&str, CliError> {
        self.token_for(provider)
            .filter(|token| !token.trim().is_empty())
            .map(str::trim)
            .ok_or_else(|| missing_token_error(provider))
    }
}

impl fmt::Debug for ExternalSyncConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ExternalSyncConfig")
            .field("github_token", &redacted(self.github_token.as_deref()))
            .field("github_repository", &self.github_repository)
            .field("todoist_token", &redacted(self.todoist_token.as_deref()))
            .finish()
    }
}

#[async_trait]
pub trait ExternalSyncClient: Send + Sync {
    #[must_use]
    fn provider(&self) -> ExternalProvider;

    /// Pull provider-side tasks.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError>;

    /// Push one task-board item to the provider.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn push_task(&self, item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError>;
}

#[derive(Clone)]
pub struct GitHubSyncClient {
    client: octocrab::Octocrab,
    repository: Option<GitHubRepository>,
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
        let token = normalize_token(ExternalProvider::GitHub, token)?;
        let repository = repository.map(parse_github_repository).transpose()?;
        ensure_rustls_provider();
        let client = octocrab::Octocrab::builder()
            .personal_token(token)
            .build()
            .map_err(github_client_error)?;
        Ok(Self { client, repository })
    }

    /// Build a GitHub client from external sync config.
    ///
    /// # Errors
    /// Returns an error when no GitHub token is configured or the SDK client
    /// cannot be built.
    pub fn from_config(config: &ExternalSyncConfig) -> Result<Self, CliError> {
        Self::new_with_repository(
            config.require_token(ExternalProvider::GitHub)?,
            config.github_repository.as_deref(),
        )
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
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl ExternalSyncClient for GitHubSyncClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        let repository = self.repository_for(None)?;
        let project_id = repository.slug();
        let page = self
            .octocrab()
            .issues(repository.owner.as_str(), repository.repo.as_str())
            .list()
            .state(State::Open)
            .per_page(100_u8)
            .send()
            .await
            .map_err(github_sync_error)?;
        let issues = self
            .octocrab()
            .all_pages(page)
            .await
            .map_err(github_sync_error)?;
        Ok(issues
            .into_iter()
            .filter(|issue| issue.pull_request.is_none())
            .map(|issue| ExternalTask {
                reference: ExternalTaskRef::new(ExternalProvider::GitHub, issue.number.to_string())
                    .with_url(issue.html_url.to_string()),
                title: issue.title,
                body: issue.body.unwrap_or_default(),
                status: TaskBoardStatus::Todo,
                project_id: Some(project_id.clone()),
                updated_at: Some(issue.updated_at.to_rfc3339()),
            })
            .collect())
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
        let issue = request.send().await.map_err(github_sync_error)?;
        Ok(
            ExternalTaskRef::new(ExternalProvider::GitHub, issue.number.to_string())
                .with_url(issue.html_url.to_string()),
        )
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

fn first_present_env(names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| read_token_env(name))
}

fn ensure_rustls_provider() {
    RUSTLS_PROVIDER.get_or_init(|| {
        let _ = default_provider().install_default();
    });
}

fn read_token_env(name: &str) -> Option<String> {
    let value = env::var(name).ok()?;
    let token = value.trim();
    (!token.is_empty()).then(|| token.to_owned())
}

fn normalize_token(
    provider: ExternalProvider,
    token: impl Into<String>,
) -> Result<String, CliError> {
    let token = token.into();
    let token = token.trim();
    if token.is_empty() {
        return Err(missing_token_error(provider));
    }
    Ok(token.to_owned())
}

fn missing_token_error(provider: ExternalProvider) -> CliError {
    let names = provider.token_env_names().join(" or ");
    CliErrorKind::workflow_io(format!(
        "task-board external sync token missing for {provider}; set {names}"
    ))
    .into()
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

fn github_client_error(error: octocrab::Error) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "create task-board github client: {error}"
    )))
    .with_source(error)
}

fn github_sync_error(error: octocrab::Error) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "task-board github sync failed: {error}"
    )))
    .with_source(error)
}

fn non_empty_body(body: &str) -> Option<String> {
    let body = body.trim();
    (!body.is_empty()).then(|| body.to_owned())
}

fn redacted(value: Option<&str>) -> &'static str {
    match value {
        Some(token) if !token.trim().is_empty() => "<redacted>",
        _ => "<unset>",
    }
}

#[cfg(test)]
mod tests;
