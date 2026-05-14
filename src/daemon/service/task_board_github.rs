use std::collections::BTreeMap;
use std::path::Path;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::errors::CliError;
use crate::task_board::github::{
    GitHubApiAutomationClient, GitHubAutomationClient, GitHubProjectConfig,
};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{
    TaskBoardItem, TaskBoardOrchestratorDispatchInput, TaskBoardOrchestratorSettings,
    TaskBoardStore,
};

mod support;
mod workflow;

use self::support::{
    automation_config, load_session_worktrees, load_session_worktrees_async, run_blocking,
};
use self::workflow::automate_item;

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
    let session_worktrees = load_session_worktrees(items, db)?;
    let client = GitHubApiAutomationClient::new(token.clone())?;
    run_blocking(run_task_board_github_automation_with_client(
        board_root,
        &config,
        input,
        items,
        &session_worktrees,
        Some(token.as_str()),
        &client,
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
    let session_worktrees = load_session_worktrees_async(items, async_db).await?;
    let client = GitHubApiAutomationClient::new(token.clone())?;
    run_task_board_github_automation_with_client(
        board_root,
        &config,
        input,
        items,
        &session_worktrees,
        Some(token.as_str()),
        &client,
    )
    .await
}

async fn run_task_board_github_automation_with_client(
    board_root: &Path,
    config: &GitHubProjectConfig,
    input: &TaskBoardOrchestratorDispatchInput,
    items: &[TaskBoardItem],
    session_worktrees: &BTreeMap<String, String>,
    github_token: Option<&str>,
    client: &dyn GitHubAutomationClient,
) -> Result<(), CliError> {
    let board = TaskBoardStore::new(board_root.to_path_buf());
    for item in items {
        let workflow = automate_item(
            board_root,
            config,
            input.project_dir.as_deref(),
            input.dry_run,
            item,
            session_worktrees,
            github_token,
            client,
        )
        .await;
        if !input.dry_run && workflow != item.workflow {
            board.update(
                &item.id,
                TaskBoardItemPatch {
                    workflow: Some(workflow),
                    ..TaskBoardItemPatch::default()
                },
            )?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
