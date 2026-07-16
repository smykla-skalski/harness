use std::collections::BTreeSet;
use std::{env, fmt};

use async_trait::async_trait;
use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::types::{ExternalRef, ExternalRefProvider, TaskBoardItem, TaskBoardStatus};

mod capabilities;
mod github;
mod scopes;
mod sync;
mod targeting;
mod todoist;

pub use capabilities::{
    ExternalProviderCapabilities, ExternalSyncConflictPolicy, ExternalSyncField,
    ExternalTaskUpdate, ExternalUpdateOutcome,
};
pub use github::{GitHubInboxSyncClient, GitHubSyncClient};
pub(crate) use github::{
    imported_review_references_from_items, reconcile_review_item_from_snapshots,
};
pub(crate) use scopes::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
    ExternalProviderScopeAvailability, ExternalProviderScopeHealth, ExternalProviderScopeIdentity,
    ExternalProviderScopeState, ExternalSyncBatch, ExternalSyncScopeOutcome,
};
pub use sync::{
    ExternalSyncAction, ExternalSyncDirection, ExternalSyncOperation, ExternalSyncOptions,
    configured_sync_clients,
};
pub(crate) use sync::{
    TaskBoardSyncStore, configured_sync_clients_without_review_requests, sync_external_tasks,
    sync_external_tasks_scoped,
};
pub use todoist::TodoistSyncClient;

pub const HARNESS_GITHUB_TOKEN_ENV: &str = "HARNESS_GITHUB_TOKEN";
pub const GH_TOKEN_ENV: &str = "GH_TOKEN";
pub const HARNESS_TODOIST_TOKEN_ENV: &str = "HARNESS_TODOIST_TOKEN";
pub const HARNESS_GITHUB_REPOSITORY_ENV: &str = "HARNESS_GITHUB_REPOSITORY";
pub const GITHUB_REPOSITORY_ENV: &str = "GITHUB_REPOSITORY";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ExternalProvider {
    #[value(name = "github", alias = "git_hub")]
    #[serde(rename = "github", alias = "git_hub")]
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
            sync_state: None,
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

pub(super) fn canonical_external_status(status: TaskBoardStatus) -> TaskBoardStatus {
    if status.canonical_persisted_status() == TaskBoardStatus::Done {
        TaskBoardStatus::Done
    } else {
        TaskBoardStatus::Backlog
    }
}

pub(super) fn local_external_status(status: TaskBoardStatus) -> Option<TaskBoardStatus> {
    match status.canonical_persisted_status() {
        TaskBoardStatus::Backlog | TaskBoardStatus::Todo => Some(TaskBoardStatus::Backlog),
        TaskBoardStatus::Done => Some(TaskBoardStatus::Done),
        _ => None,
    }
}

#[derive(Clone, Default, PartialEq, Eq)]
pub struct ExternalSyncConfig {
    pub github_token: Option<String>,
    pub github_repository: Option<String>,
    pub github_inbox_repositories: Vec<String>,
    pub github_import_labels: Vec<String>,
    pub todoist_token: Option<String>,
    pub todoist_import_project_ids: Vec<String>,
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
            github_inbox_repositories: Vec::new(),
            github_import_labels: Vec::new(),
            todoist_token: first_present_env(&[HARNESS_TODOIST_TOKEN_ENV]),
            todoist_import_project_ids: Vec::new(),
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
    pub fn github_inbox_repositories(&self) -> &[String] {
        &self.github_inbox_repositories
    }

    #[must_use]
    pub fn github_import_labels(&self) -> &[String] {
        &self.github_import_labels
    }

    #[must_use]
    pub fn todoist_import_project_ids(&self) -> &[String] {
        &self.todoist_import_project_ids
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

    #[must_use]
    pub fn with_github_inbox_repositories_override(mut self, repositories: &[String]) -> Self {
        self.github_inbox_repositories = repositories
            .iter()
            .map(String::as_str)
            .map(str::trim)
            .filter(|repository| !repository.is_empty())
            .map(ToOwned::to_owned)
            .collect();
        self
    }

    #[must_use]
    pub fn with_github_import_labels_override(mut self, labels: &[String]) -> Self {
        self.github_import_labels = normalize_string_list(labels);
        self
    }

    #[must_use]
    pub fn with_todoist_import_project_ids_override(mut self, project_ids: &[String]) -> Self {
        self.todoist_import_project_ids = normalize_string_list(project_ids);
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
            .field("github_inbox_repositories", &self.github_inbox_repositories)
            .field("github_import_labels", &self.github_import_labels)
            .field("todoist_token", &redacted(self.todoist_token.as_deref()))
            .field(
                "todoist_import_project_ids",
                &self.todoist_import_project_ids,
            )
            .finish()
    }
}

fn normalize_string_list(values: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::with_capacity(values.len());
    for value in values {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            continue;
        }
        if seen.insert(trimmed.to_owned()) {
            out.push(trimmed.to_owned());
        }
    }
    out
}

#[async_trait]
pub trait ExternalSyncClient: Send + Sync {
    #[must_use]
    fn provider(&self) -> ExternalProvider;

    #[must_use]
    fn scope_id(&self) -> String {
        self.provider().to_string()
    }

    #[must_use]
    fn scope_for_item(&self, _item: &TaskBoardItem) -> String {
        self.scope_id()
    }

    #[must_use]
    fn capabilities(&self) -> ExternalProviderCapabilities {
        ExternalProviderCapabilities::creates_only()
    }

    #[must_use]
    fn allows_pull(&self) -> bool {
        true
    }

    #[must_use]
    fn allows_push(&self) -> bool {
        true
    }

    #[must_use]
    fn allows_delete(&self) -> bool {
        false
    }

    /// Whether this client's pull result is the complete set of active GitHub
    /// review requests and can therefore close omitted imported reviews.
    #[must_use]
    fn authoritative_review_inbox(&self) -> bool {
        false
    }

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

    /// Update one linked provider task.
    ///
    /// Implementations that honour `update.precondition_updated_at` may return
    /// `ExternalUpdateOutcome::PreconditionFailed` when the remote task changed
    /// since the precondition timestamp. The sync layer surfaces that as a
    /// conflict and skips the write.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn update_task(
        &self,
        _item: &TaskBoardItem,
        reference: &ExternalTaskRef,
        _update: ExternalTaskUpdate,
    ) -> Result<ExternalUpdateOutcome, CliError> {
        Err(CliErrorKind::workflow_io(format!(
            "task-board {} sync does not support updating linked remote items '{}'",
            self.provider(),
            reference.external_id
        ))
        .into())
    }

    /// Delete (or close) one linked provider task. Default is a no-op so
    /// pull-only clients keep working without explicit opt-out.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn delete_task(
        &self,
        _item: &TaskBoardItem,
        _reference: &ExternalTaskRef,
    ) -> Result<(), CliError> {
        Ok(())
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

pub(super) fn normalize_token(
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

pub(super) fn non_empty_body(body: &str) -> Option<String> {
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
mod sync_tests;
#[cfg(test)]
mod tests;
