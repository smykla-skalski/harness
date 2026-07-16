use std::fmt;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::super::types::{ExternalRefProvider, TaskBoardItem, TaskBoardStatus};
use super::{
    ExternalProvider, ExternalProviderCapabilities, ExternalSyncClient, ExternalSyncConfig,
    ExternalSyncField, ExternalTask, ExternalTaskRef, ExternalTaskUpdate, ExternalUpdateOutcome,
    non_empty_body, normalize_token,
};

const TODOIST_API_BASE: &str = "https://api.todoist.com/rest/v2";

#[derive(Clone)]
pub struct TodoistSyncClient {
    token: String,
    api_base: String,
    client: reqwest::Client,
    import_project_ids: Vec<String>,
}

impl TodoistSyncClient {
    /// Build a Todoist client from a token.
    ///
    /// # Errors
    /// Returns an error when the token is empty.
    pub fn new(token: impl Into<String>) -> Result<Self, CliError> {
        Self::new_with_api_base(token, TODOIST_API_BASE)
    }

    /// Build a Todoist client with a custom API base URL.
    ///
    /// # Errors
    /// Returns an error when the token or base URL is empty.
    pub fn new_with_api_base(
        token: impl Into<String>,
        api_base: impl Into<String>,
    ) -> Result<Self, CliError> {
        let api_base = api_base.into();
        let api_base = api_base.trim().trim_end_matches('/');
        if api_base.is_empty() {
            return Err(CliErrorKind::workflow_io("todoist api base URL is empty").into());
        }
        Ok(Self {
            token: normalize_token(ExternalProvider::Todoist, token)?,
            api_base: api_base.to_owned(),
            client: reqwest::Client::new(),
            import_project_ids: Vec::new(),
        })
    }

    /// Build a Todoist client from external sync config.
    ///
    /// # Errors
    /// Returns an error when no Todoist token is configured.
    pub fn from_config(config: &ExternalSyncConfig) -> Result<Self, CliError> {
        let mut client = Self::new(config.require_token(ExternalProvider::Todoist)?)?;
        client.import_project_ids = config.todoist_import_project_ids().to_vec();
        Ok(client)
    }

    #[must_use]
    pub fn project_filter(&self) -> &[String] {
        &self.import_project_ids
    }

    #[must_use]
    pub fn token_is_configured(&self) -> bool {
        !self.token.is_empty()
    }

    fn endpoint(&self, path: &str) -> String {
        format!("{}/{}", self.api_base, path.trim_start_matches('/'))
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

    fn scope_id(&self) -> String {
        match self.import_project_ids.as_slice() {
            [project_id] => project_id.clone(),
            _ => "all".into(),
        }
    }

    fn scope_for_item(&self, item: &TaskBoardItem) -> String {
        if self.import_project_ids.is_empty() {
            return self.scope_id();
        }
        item.project_id
            .clone()
            .or_else(|| {
                item.external_refs
                    .iter()
                    .find(|reference| reference.provider == ExternalRefProvider::Todoist)
                    .and_then(|reference| reference.sync_state.as_ref())
                    .and_then(|state| state.project_id.clone())
            })
            .unwrap_or_default()
    }

    fn capabilities(&self) -> ExternalProviderCapabilities {
        ExternalProviderCapabilities::with_update_fields([
            ExternalSyncField::Title,
            ExternalSyncField::Body,
            ExternalSyncField::Status,
            ExternalSyncField::Project,
        ])
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        let tasks = self
            .client
            .get(self.endpoint("tasks"))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(todoist_sync_error)?
            .error_for_status()
            .map_err(todoist_sync_error)?
            .json::<Vec<TodoistTask>>()
            .await
            .map_err(todoist_sync_error)?;
        let project_filter = self.import_project_ids.as_slice();
        Ok(tasks
            .into_iter()
            .filter(|task| {
                todoist_project_matches_filter(task.project_id.as_deref(), project_filter)
            })
            .map(ExternalTask::from)
            .collect())
    }

    async fn push_task(&self, item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        let request = TodoistCreateTaskRequest {
            content: item.title.clone(),
            description: non_empty_body(&item.body),
            project_id: item.project_id.clone(),
        };
        let task = self
            .client
            .post(self.endpoint("tasks"))
            .bearer_auth(&self.token)
            .json(&request)
            .send()
            .await
            .map_err(todoist_sync_error)?
            .error_for_status()
            .map_err(todoist_sync_error)?
            .json::<TodoistTask>()
            .await
            .map_err(todoist_sync_error)?;
        Ok(task.reference())
    }

    async fn update_task(
        &self,
        item: &TaskBoardItem,
        reference: &ExternalTaskRef,
        update: ExternalTaskUpdate,
    ) -> Result<ExternalUpdateOutcome, CliError> {
        if let Some(precondition) = update.precondition_updated_at.as_deref() {
            let current = self.fetch_task(&reference.external_id).await?;
            if current.updated_at.as_deref() != Some(precondition) {
                return Ok(ExternalUpdateOutcome::PreconditionFailed);
            }
        }
        let mut updated_reference = reference.clone();
        let mut provider_revision = None;
        if update.changes_metadata() {
            let updated = self.update_task_metadata(item, reference, &update).await?;
            updated_reference = updated.reference();
            provider_revision = updated.updated_at;
        }
        if update.changes_status() {
            self.update_task_status(item, reference).await?;
            provider_revision = None;
        }
        Ok(ExternalUpdateOutcome::Applied {
            reference: updated_reference,
            provider_revision,
        })
    }

    fn allows_delete(&self) -> bool {
        true
    }

    async fn delete_task(
        &self,
        _item: &TaskBoardItem,
        reference: &ExternalTaskRef,
    ) -> Result<(), CliError> {
        self.client
            .post(self.endpoint(format!("tasks/{}/close", reference.external_id).as_str()))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(todoist_sync_error)?
            .error_for_status()
            .map_err(todoist_sync_error)?;
        Ok(())
    }
}

impl TodoistSyncClient {
    async fn fetch_task(&self, external_id: &str) -> Result<TodoistTask, CliError> {
        self.client
            .get(self.endpoint(format!("tasks/{external_id}").as_str()))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(todoist_sync_error)?
            .error_for_status()
            .map_err(todoist_sync_error)?
            .json::<TodoistTask>()
            .await
            .map_err(todoist_sync_error)
    }

    async fn update_task_metadata(
        &self,
        item: &TaskBoardItem,
        reference: &ExternalTaskRef,
        update: &ExternalTaskUpdate,
    ) -> Result<TodoistTask, CliError> {
        let request = TodoistUpdateTaskRequest {
            content: update
                .changed_fields
                .contains(&ExternalSyncField::Title)
                .then(|| item.title.clone()),
            description: update
                .changed_fields
                .contains(&ExternalSyncField::Body)
                .then(|| item.body.clone()),
            project_id: update
                .changed_fields
                .contains(&ExternalSyncField::Project)
                .then(|| item.project_id.clone())
                .flatten(),
        };
        let task = self
            .client
            .post(self.endpoint(format!("tasks/{}", reference.external_id).as_str()))
            .bearer_auth(&self.token)
            .json(&request)
            .send()
            .await
            .map_err(todoist_sync_error)?
            .error_for_status()
            .map_err(todoist_sync_error)?
            .json::<TodoistTask>()
            .await
            .map_err(todoist_sync_error)?;
        Ok(task)
    }

    async fn update_task_status(
        &self,
        item: &TaskBoardItem,
        reference: &ExternalTaskRef,
    ) -> Result<(), CliError> {
        self.client
            .post(self.endpoint(status_endpoint(&reference.external_id, item.status).as_str()))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(todoist_sync_error)?
            .error_for_status()
            .map_err(todoist_sync_error)?;
        Ok(())
    }
}

impl ExternalTaskUpdate {
    fn changes_metadata(&self) -> bool {
        self.changed_fields.iter().any(|field| {
            matches!(
                field,
                ExternalSyncField::Title | ExternalSyncField::Body | ExternalSyncField::Project
            )
        })
    }

    fn changes_status(&self) -> bool {
        self.changed_fields.contains(&ExternalSyncField::Status)
    }
}

fn status_endpoint(external_id: &str, status: TaskBoardStatus) -> String {
    let action = if status == TaskBoardStatus::Done {
        "close"
    } else {
        "reopen"
    };
    format!("tasks/{external_id}/{action}")
}

#[derive(Debug, Serialize)]
struct TodoistCreateTaskRequest {
    content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    project_id: Option<String>,
}

#[derive(Debug, Serialize)]
struct TodoistUpdateTaskRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    project_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TodoistTask {
    id: String,
    content: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    project_id: Option<String>,
    #[serde(default)]
    updated_at: Option<String>,
}

impl TodoistTask {
    fn reference(&self) -> ExternalTaskRef {
        let mut reference = ExternalTaskRef::new(ExternalProvider::Todoist, self.id.clone());
        if let Some(url) = &self.url {
            reference = reference.with_url(url.clone());
        }
        reference
    }
}

impl From<TodoistTask> for ExternalTask {
    fn from(task: TodoistTask) -> Self {
        Self {
            reference: task.reference(),
            title: task.content,
            body: task.description,
            status: TaskBoardStatus::Backlog,
            project_id: task.project_id,
            updated_at: task.updated_at,
        }
    }
}

fn todoist_project_matches_filter(project_id: Option<&str>, allowed: &[String]) -> bool {
    if allowed.is_empty() {
        return true;
    }
    let Some(project_id) = project_id else {
        return false;
    };
    allowed
        .iter()
        .any(|wanted| wanted.trim().eq_ignore_ascii_case(project_id.trim()))
}

fn todoist_sync_error(error: reqwest::Error) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "task-board todoist sync failed: {error}"
    )))
    .with_source(error)
}

#[cfg(test)]
mod todoist_tests;
