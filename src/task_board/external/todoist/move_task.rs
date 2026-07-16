use serde::Serialize;

use crate::errors::CliError;

use super::{
    ExternalTaskRef, TaskBoardItem, TodoistRequestIntent, TodoistSyncClient, TodoistTask,
    todoist_sync_error,
};

#[derive(Debug, Serialize)]
pub(super) struct TodoistMoveTaskRequest {
    pub(super) project_id: String,
}

pub(super) async fn move_task(
    client: &TodoistSyncClient,
    item: &TaskBoardItem,
    reference: &ExternalTaskRef,
    project_id: &str,
) -> Result<TodoistTask, CliError> {
    let request = TodoistMoveTaskRequest {
        project_id: project_id.to_owned(),
    };
    let request_id = TodoistRequestIntent::Move {
        item,
        external_id: &reference.external_id,
        request: &request,
    }
    .request_id();
    client
        .write_request(
            client
                .client
                .post(client.endpoint(format!("tasks/{}/move", reference.external_id).as_str())),
            &request_id,
        )
        .json(&request)
        .send()
        .await
        .map_err(todoist_sync_error)?
        .error_for_status()
        .map_err(todoist_sync_error)?
        .json::<TodoistTask>()
        .await
        .map_err(todoist_sync_error)
}
