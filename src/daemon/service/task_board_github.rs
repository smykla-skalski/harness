use std::collections::BTreeMap;
use std::path::Path;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::errors::CliError;
use crate::github_api::{GitHubProtectedClient, republish_current_data_change};
use crate::task_board::github::{
    GitHubApiAutomationClient, GitHubAutomationClient, GitHubProjectConfig,
};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{
    MachineRegistry, TaskBoardItem, TaskBoardOrchestratorDispatchInput,
    TaskBoardOrchestratorSettings, TaskBoardStore,
};

mod support;
mod workflow;

use self::support::{
    automation_config, load_session_worktrees, load_session_worktrees_async, run_blocking,
};
use self::workflow::automate_item;

pub(super) struct AutomationRequest<'a> {
    pub board_root: &'a Path,
    pub config: &'a GitHubProjectConfig,
    pub project_dir: Option<&'a str>,
    pub dry_run: bool,
    pub item: &'a TaskBoardItem,
    pub session_worktrees: &'a BTreeMap<String, String>,
    pub client: &'a dyn GitHubAutomationClient,
    pub host_id: &'a str,
}

pub(crate) fn run_task_board_github_automation(
    board_root: &Path,
    settings: &TaskBoardOrchestratorSettings,
    input: &TaskBoardOrchestratorDispatchInput,
    items: &[TaskBoardItem],
    db: Option<&DaemonDb>,
) -> Result<(), CliError> {
    let Some((config, token)) = automation_config(settings) else {
        return Ok(());
    };
    let host_id = MachineRegistry::new(board_root.to_path_buf())
        .ensure_local()?
        .id;
    let session_worktrees = load_session_worktrees(items, db)?;
    let client = GitHubApiAutomationClient::new(token.as_str())?;
    run_blocking(run_task_board_github_automation_with_client(
        board_root,
        &config,
        input,
        items,
        &session_worktrees,
        &client,
        host_id.as_str(),
    ))
}

pub(crate) async fn run_task_board_github_automation_async(
    board_root: &Path,
    settings: &TaskBoardOrchestratorSettings,
    input: &TaskBoardOrchestratorDispatchInput,
    items: &[TaskBoardItem],
    async_db: &AsyncDaemonDb,
) -> Result<(), CliError> {
    let Some((config, token)) = automation_config(settings) else {
        return Ok(());
    };
    let host_id = MachineRegistry::new(board_root.to_path_buf())
        .ensure_local()?
        .id;
    let session_worktrees = load_session_worktrees_async(items, async_db).await?;
    let client = GitHubApiAutomationClient::new(token.as_str())?;
    run_task_board_github_automation_with_client(
        board_root,
        &config,
        input,
        items,
        &session_worktrees,
        &client,
        host_id.as_str(),
    )
    .await
}

async fn run_task_board_github_automation_with_client(
    board_root: &Path,
    config: &GitHubProjectConfig,
    input: &TaskBoardOrchestratorDispatchInput,
    items: &[TaskBoardItem],
    session_worktrees: &BTreeMap<String, String>,
    client: &dyn GitHubAutomationClient,
    host_id: &str,
) -> Result<(), CliError> {
    let board = TaskBoardStore::new(board_root.to_path_buf());
    for item in items {
        let revision_before = GitHubProtectedClient::data_revision();
        let workflow = automate_item(AutomationRequest {
            board_root,
            config,
            item,
            session_worktrees,
            project_dir: input.project_dir.as_deref(),
            dry_run: input.dry_run,
            client,
            host_id,
        })
        .await;
        if !input.dry_run && workflow != item.workflow {
            board.update(
                &item.id,
                TaskBoardItemPatch {
                    workflow: Some(workflow),
                    ..TaskBoardItemPatch::default()
                },
            )?;
            if GitHubProtectedClient::data_revision() != revision_before {
                republish_current_data_change("task_board.github.local_automation_ready");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
