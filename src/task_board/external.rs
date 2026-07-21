use std::fmt;

use async_trait::async_trait;
use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::types::{ExternalRef, ExternalRefProvider, TaskBoardItem, TaskBoardStatus};

mod capabilities;
mod config;
mod create_recovery;
mod github;
mod scopes;
mod sync;
mod targeting;
mod todoist;

pub use capabilities::{
    ExternalProviderCapabilities, ExternalRevisionUpdate, ExternalSyncConflictPolicy,
    ExternalSyncField, ExternalTaskUpdate, ExternalUpdateOutcome,
};
pub use config::ExternalSyncConfig;
pub(crate) use create_recovery::ExternalCreateRecoveryClient;
#[allow(
    unused_imports,
    reason = "shared contract is consumed by follow-up provider recovery slices"
)]
pub(crate) use create_recovery::{ExternalCreateLease, ExternalCreateProbe, ExternalCreateRequest};
pub use github::{GitHubInboxSyncClient, GitHubSyncClient};
pub(crate) use github::{
    imported_review_references_from_items, reconcile_review_item_from_snapshots,
};
pub(crate) use scopes::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
    ExternalProviderScopeAvailability, ExternalProviderScopeHealth, ExternalProviderScopeIdentity,
    ExternalProviderScopeState, ExternalSyncBatch, ExternalSyncScopeOutcome,
};
#[cfg(test)]
pub(crate) use sync::sync_external_tasks_scoped;
pub use sync::{
    ExternalSyncAction, ExternalSyncDirection, ExternalSyncOperation, ExternalSyncOptions,
    configured_sync_clients,
};
pub(crate) use sync::{
    TaskBoardExternalCreateStore, TaskBoardSyncCoordinatorFence,
    TaskBoardSyncCoordinatorFenceDecision, TaskBoardSyncItemSnapshot, TaskBoardSyncStore,
    assign_external_create_recovery, blocked_external_create_follow_ups,
    blocked_external_create_recovery, configured_sync_clients_without_review_requests,
    load_external_create_recovery_work, prepare_external_create_recovery, sync_external_tasks,
    sync_external_tasks_scoped_with_recovery,
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalCreateOutcome {
    pub reference: ExternalTaskRef,
    pub provider_revision: Option<String>,
    pub provider_project_id: Option<String>,
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
    /// Provider labels, mapped onto board tags. Only GitHub populates this today.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub labels: Vec<String>,
    /// The tracking issue this task is "part of", resolved to a local item on import.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_reference: Option<ExternalTaskRef>,
    /// Whether the provider reports this task as tracking children of its own.
    #[serde(default)]
    pub tracks_children: bool,
}

impl Default for ExternalTask {
    fn default() -> Self {
        Self {
            reference: ExternalTaskRef::new(ExternalProvider::GitHub, String::new()),
            title: String::new(),
            body: String::new(),
            status: TaskBoardStatus::default(),
            project_id: None,
            updated_at: None,
            labels: Vec::new(),
            parent_reference: None,
            tracks_children: false,
        }
    }
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

#[async_trait]
pub trait ExternalSyncClient: Send + Sync {
    #[must_use]
    fn provider(&self) -> ExternalProvider;

    /// Return the crash-safe provider-create capability when implemented.
    ///
    /// Absence is fail-closed by the recovery engine; it never authorizes a
    /// create or treats an existing durable attempt as recovered.
    #[must_use]
    #[allow(
        private_interfaces,
        reason = "provider-create recovery is intentionally crate-private"
    )]
    fn external_create_recovery(&self) -> Option<&dyn ExternalCreateRecoveryClient> {
        None
    }

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

    /// Push one task-board item and return provider state needed for later writes.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn push_task_with_outcome(
        &self,
        item: &TaskBoardItem,
    ) -> Result<ExternalCreateOutcome, CliError> {
        Ok(ExternalCreateOutcome {
            reference: self.push_task(item).await?,
            provider_revision: None,
            provider_project_id: (self.provider() != ExternalProvider::GitHub)
                .then(|| item.project_id.clone())
                .flatten(),
        })
    }

    /// Update one linked provider task.
    ///
    /// Implementations that honour `update.precondition_updated_at` may return
    /// `ExternalUpdateOutcome::PreconditionFailed` when the remote task changed
    /// since the precondition timestamp. The sync layer surfaces that as a
    /// conflict and skips the write. Applied updates must set or clear provider
    /// revision state after a mutation, preserving it only when no revision-changing
    /// write occurred.
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

#[cfg(test)]
mod sync_tests;
#[cfg(test)]
mod tests;
