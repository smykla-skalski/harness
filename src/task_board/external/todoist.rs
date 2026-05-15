use std::fmt;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::super::types::{TaskBoardItem, TaskBoardStatus};
use super::{
    ExternalProvider, ExternalProviderCapabilities, ExternalSyncClient, ExternalSyncConfig,
    ExternalSyncField, ExternalTask, ExternalTaskRef, ExternalTaskUpdate, non_empty_body,
    normalize_token,
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

    async fn update_task(
        &self,
        item: &TaskBoardItem,
        reference: &ExternalTaskRef,
        update: ExternalTaskUpdate,
    ) -> Result<ExternalTaskRef, CliError> {
        let mut updated_reference = reference.clone();
        if update.changes_metadata() {
            updated_reference = self.update_task_metadata(item, reference, &update).await?;
        }
        if update.changes_status() {
            self.update_task_status(item, reference).await?;
        }
        Ok(updated_reference)
    }
}

impl TodoistSyncClient {
    async fn update_task_metadata(
        &self,
        item: &TaskBoardItem,
        reference: &ExternalTaskRef,
        update: &ExternalTaskUpdate,
    ) -> Result<ExternalTaskRef, CliError> {
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
        Ok(task.reference())
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
            project_id: None,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn todoist_capabilities_include_status_updates() {
        let client = TodoistSyncClient::new_with_api_base("token", "https://todoist.invalid")
            .expect("client");

        assert!(
            client
                .capabilities()
                .supports_update(ExternalSyncField::Status)
        );
    }

    #[test]
    fn todoist_status_endpoint_closes_done_and_reopens_other_statuses() {
        assert_eq!(
            status_endpoint("task-1", TaskBoardStatus::Done),
            "tasks/task-1/close"
        );
        assert_eq!(
            status_endpoint("task-1", TaskBoardStatus::Todo),
            "tasks/task-1/reopen"
        );
    }

    #[test]
    fn todoist_update_classifies_metadata_and_status_changes() {
        let metadata = ExternalTaskUpdate::new(vec![ExternalSyncField::Title]);
        let status = ExternalTaskUpdate::new(vec![ExternalSyncField::Status]);

        assert!(metadata.changes_metadata());
        assert!(!metadata.changes_status());
        assert!(!status.changes_metadata());
        assert!(status.changes_status());
    }
}
