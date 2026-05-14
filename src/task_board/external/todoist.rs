use std::fmt;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::super::types::{TaskBoardItem, TaskBoardStatus};
use super::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConfig, ExternalTask, ExternalTaskRef,
    non_empty_body, normalize_token,
};

const TODOIST_API_BASE: &str = "https://api.todoist.com/rest/v2";

#[derive(Clone)]
pub struct TodoistSyncClient {
    token: String,
    api_base: String,
    client: reqwest::Client,
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
        })
    }

    /// Build a Todoist client from external sync config.
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
        Ok(tasks.into_iter().map(ExternalTask::from).collect())
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
}

#[derive(Debug, Serialize)]
struct TodoistCreateTaskRequest {
    content: String,
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
            status: TaskBoardStatus::Todo,
            updated_at: None,
        }
    }
}

fn todoist_sync_error(error: reqwest::Error) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "task-board todoist sync failed: {error}"
    )))
    .with_source(error)
}
