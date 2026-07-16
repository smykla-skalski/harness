use std::collections::HashSet;

use serde::{Deserialize, Deserializer};

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::ExternalTask;

use super::{TodoistSyncClient, TodoistTask, todoist_project_matches_filter, todoist_sync_error};

#[derive(Debug, Deserialize)]
struct TodoistTaskPage {
    results: Vec<TodoistTask>,
    #[serde(default)]
    next_cursor: TodoistNextCursor,
}

#[derive(Debug, Default)]
enum TodoistNextCursor {
    #[default]
    Missing,
    Present(Option<String>),
}

impl<'de> Deserialize<'de> for TodoistNextCursor {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Option::<String>::deserialize(deserializer).map(Self::Present)
    }
}

pub(super) async fn pull_tasks(client: &TodoistSyncClient) -> Result<Vec<ExternalTask>, CliError> {
    let mut tasks = Vec::new();
    let mut cursor = None;
    let mut seen_cursors = HashSet::new();
    loop {
        let page = pull_page(client, cursor.as_deref()).await?;
        let project_filter = client.import_project_ids.as_slice();
        tasks.extend(
            page.results
                .into_iter()
                .filter(|task| {
                    todoist_project_matches_filter(task.project_id.as_deref(), project_filter)
                })
                .map(ExternalTask::from),
        );
        let next_cursor = match page.next_cursor {
            TodoistNextCursor::Missing => {
                return Err(pagination_error("missing pagination cursor"));
            }
            TodoistNextCursor::Present(None) => break,
            TodoistNextCursor::Present(Some(next_cursor)) => next_cursor,
        };
        if next_cursor.trim().is_empty() {
            return Err(pagination_error("empty pagination cursor"));
        }
        if !seen_cursors.insert(next_cursor.clone()) {
            return Err(pagination_error("repeated pagination cursor"));
        }
        cursor = Some(next_cursor);
    }
    Ok(tasks)
}

async fn pull_page(
    client: &TodoistSyncClient,
    cursor: Option<&str>,
) -> Result<TodoistTaskPage, CliError> {
    let mut request = client
        .client
        .get(client.endpoint("tasks"))
        .bearer_auth(&client.token);
    if let Some(cursor) = cursor {
        request = request.query(&[("cursor", cursor)]);
    }
    request
        .send()
        .await
        .map_err(todoist_sync_error)?
        .error_for_status()
        .map_err(todoist_sync_error)?
        .json::<TodoistTaskPage>()
        .await
        .map_err(todoist_sync_error)
}

fn pagination_error(detail: &str) -> CliError {
    CliErrorKind::workflow_io(format!("task-board todoist sync failed: {detail}")).into()
}
