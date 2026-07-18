use std::collections::BTreeMap;
#[cfg(test)]
use std::path::Path;

use crate::daemon::db::AsyncDaemonDb;
#[cfg(test)]
use crate::daemon::db::DaemonDb;
#[cfg(test)]
use crate::daemon::state::load_task_board_git_runtime_config;
use crate::daemon::state::overlay_task_board_git_runtime_secrets;
use crate::errors::CliError;
#[cfg(test)]
use crate::github_api::{GitHubProtectedClient, republish_current_data_change};
use crate::task_board::github::{
    GitHubApiAutomationClient, GitHubAutomationClient, GitHubProjectConfig,
};
#[cfg(test)]
use crate::task_board::store::TaskBoardItemPatch;
#[cfg(test)]
use crate::task_board::{MachineRegistry, TaskBoardStore};
use crate::task_board::{
    PolicyGraph, TaskBoardItem, TaskBoardOrchestratorDispatchInput, TaskBoardOrchestratorSettings,
};

mod support;
mod workflow;
mod write_publication;

#[cfg(test)]
use write_publication::{parse_publication_url, reconcile_publication_number};
pub(crate) use write_publication::{
    publish_task_board_write_execution, validate_write_workflow_launch_publication,
    verify_task_board_write_execution_publication,
};

use self::support::{automation_config, load_session_worktrees_async};
#[cfg(test)]
use self::support::{load_session_worktrees, run_blocking};
#[cfg(test)]
use self::workflow::automate_item;
use self::workflow::automate_item_with_database_policy;

#[cfg(test)]
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

pub(super) struct DatabaseAutomationRequest<'a> {
    pub policy: Option<(&'a str, &'a PolicyGraph)>,
    pub config: &'a GitHubProjectConfig,
    pub project_dir: Option<&'a str>,
    pub dry_run: bool,
    pub item: &'a TaskBoardItem,
    pub session_worktrees: &'a BTreeMap<String, String>,
    pub client: &'a dyn GitHubAutomationClient,
    pub host_id: &'a str,
}

#[cfg(test)]
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
    let mut runtime_config = load_task_board_git_runtime_config()?;
    overlay_task_board_git_runtime_secrets(&mut runtime_config);
    let client =
        GitHubApiAutomationClient::new_with_runtime_config(token.as_str(), runtime_config)?;
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
    settings: &TaskBoardOrchestratorSettings,
    input: &TaskBoardOrchestratorDispatchInput,
    items: &[TaskBoardItem],
    async_db: &AsyncDaemonDb,
) -> Result<(), CliError> {
    let Some((config, token)) = automation_config(settings) else {
        return Ok(());
    };
    let host_id = super::task_board_db::task_board_host_local_db(async_db)
        .await?
        .id;
    let session_worktrees = load_session_worktrees_async(items, async_db).await?;
    let workspace = async_db.load_policy_workspace().await?;
    let policy = workspace.as_ref().and_then(|workspace| {
        workspace
            .active_live_canvas()
            .map(|(canvas, document)| (canvas.id.as_str(), document))
    });
    let mut runtime_config = async_db.task_board_runtime_config().await?;
    overlay_task_board_git_runtime_secrets(&mut runtime_config);
    let client =
        GitHubApiAutomationClient::new_with_runtime_config(token.as_str(), runtime_config)?;
    run_task_board_github_automation_with_database_client(
        async_db,
        policy,
        &config,
        input,
        items,
        &session_worktrees,
        &client,
        host_id.as_str(),
    )
    .await
}

#[cfg(test)]
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

#[expect(
    clippy::too_many_arguments,
    reason = "database automation keeps the policy, sync input, client, and host context explicit"
)]
async fn run_task_board_github_automation_with_database_client(
    db: &AsyncDaemonDb,
    policy: Option<(&str, &PolicyGraph)>,
    config: &GitHubProjectConfig,
    input: &TaskBoardOrchestratorDispatchInput,
    items: &[TaskBoardItem],
    session_worktrees: &BTreeMap<String, String>,
    client: &dyn GitHubAutomationClient,
    host_id: &str,
) -> Result<(), CliError> {
    for item in items {
        let workflow = automate_item_with_database_policy(DatabaseAutomationRequest {
            policy,
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
            db.update_task_board_item(&item.id, |current| {
                current.workflow.clone_from(&workflow);
                Ok(true)
            })
            .await?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
#[cfg(test)]
#[path = "task_board_github/write_publication_tests.rs"]
mod write_publication_tests;
