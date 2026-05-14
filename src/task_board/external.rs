use std::{env, fmt};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::types::{ExternalRef, ExternalRefProvider, TaskBoardItem, TaskBoardStatus};

pub const HARNESS_GITHUB_TOKEN_ENV: &str = "HARNESS_GITHUB_TOKEN";
pub const GH_TOKEN_ENV: &str = "GH_TOKEN";
pub const HARNESS_TODOIST_TOKEN_ENV: &str = "HARNESS_TODOIST_TOKEN";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
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
    pub updated_at: Option<String>,
}

#[derive(Clone, Default, PartialEq, Eq)]
pub struct ExternalSyncConfig {
    pub github_token: Option<String>,
    pub todoist_token: Option<String>,
}

impl ExternalSyncConfig {
    #[must_use]
    pub fn from_env() -> Self {
        Self {
            github_token: first_present_env(&[HARNESS_GITHUB_TOKEN_ENV, GH_TOKEN_ENV]),
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
}

impl GitHubSyncClient {
    /// Build a GitHub client from a token using the native GitHub SDK.
    ///
    /// # Errors
    /// Returns an error when the token is empty or the SDK client cannot be built.
    pub fn new(token: impl Into<String>) -> Result<Self, CliError> {
        let token = normalize_token(ExternalProvider::GitHub, token)?;
        let client = octocrab::Octocrab::builder()
            .personal_token(token)
            .build()
            .map_err(github_client_error)?;
        Ok(Self { client })
    }

    /// Build a GitHub client from external sync config.
    ///
    /// # Errors
    /// Returns an error when no GitHub token is configured or the SDK client
    /// cannot be built.
    pub fn from_config(config: &ExternalSyncConfig) -> Result<Self, CliError> {
        Self::new(config.require_token(ExternalProvider::GitHub)?)
    }

    #[must_use]
    pub const fn octocrab(&self) -> &octocrab::Octocrab {
        &self.client
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
        let _client = self.octocrab();
        Err(sync_not_implemented_error(self.provider(), "pull tasks"))
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        let _client = self.octocrab();
        Err(sync_not_implemented_error(self.provider(), "push task"))
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct TodoistSyncClient {
    token: String,
}

impl TodoistSyncClient {
    /// Build a Todoist placeholder client from a token.
    ///
    /// # Errors
    /// Returns an error when the token is empty.
    pub fn new(token: impl Into<String>) -> Result<Self, CliError> {
        Ok(Self {
            token: normalize_token(ExternalProvider::Todoist, token)?,
        })
    }

    /// Build a Todoist placeholder client from external sync config.
    ///
    /// # Errors
    /// Returns an error when no Todoist token is configured.
    pub fn from_config(config: &ExternalSyncConfig) -> Result<Self, CliError> {
        Self::new(config.require_token(ExternalProvider::Todoist)?)
    }

    #[must_use]
    pub fn token_is_configured(&self) -> bool {
        !self.token.is_empty()
    }
}

impl fmt::Debug for TodoistSyncClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TodoistSyncClient")
            .field("provider", &ExternalProvider::Todoist)
            .field("token", &"<redacted>")
            .finish()
    }
}

#[async_trait]
impl ExternalSyncClient for TodoistSyncClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::Todoist
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        let _configured = self.token_is_configured();
        Err(sync_not_implemented_error(self.provider(), "pull tasks"))
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        let _configured = self.token_is_configured();
        Err(sync_not_implemented_error(self.provider(), "push task"))
    }
}

fn first_present_env(names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| read_token_env(name))
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

fn sync_not_implemented_error(provider: ExternalProvider, operation: &str) -> CliError {
    CliErrorKind::workflow_io(format!(
        "task-board external sync {operation} is not implemented for {provider}"
    ))
    .into()
}

fn github_client_error(error: octocrab::Error) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "create task-board github client: {error}"
    )))
    .with_source(error)
}

fn redacted(value: Option<&str>) -> &'static str {
    match value {
        Some(token) if !token.trim().is_empty() => "<redacted>",
        _ => "<unset>",
    }
}

#[cfg(test)]
mod tests;
