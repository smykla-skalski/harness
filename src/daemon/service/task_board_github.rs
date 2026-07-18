use std::collections::BTreeMap;
#[cfg(test)]
use std::path::Path;

use crate::daemon::db::AsyncDaemonDb;
#[cfg(test)]
use crate::daemon::db::DaemonDb;
#[cfg(test)]
use crate::daemon::state::load_task_board_git_runtime_config;
use crate::daemon::state::overlay_task_board_git_runtime_secrets;
use crate::errors::{CliError, CliErrorKind};
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
    PolicyGraph, TaskBoardItem, TaskBoardLifecycleOutcome, TaskBoardOrchestratorDispatchInput,
    TaskBoardOrchestratorSettings, TaskBoardStatus, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowKind, normalize_repository_slug,
};

mod support;
mod workflow;

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

pub(crate) async fn publish_task_board_write_execution(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<TaskBoardLifecycleOutcome, CliError> {
    let (config, client, repository) = write_publication_client(db, execution).await?;
    let mut item = db.task_board_item(&execution.item_id).await?;
    item.status = TaskBoardStatus::InReview;
    item.workflow.last_error = None;
    if let Some(pull_request) = execution.transition.pull_request.as_ref() {
        item.workflow.pr_number = Some(pull_request.number);
        item.workflow.pr_url = Some(format!(
            "https://github.com/{}/pull/{}",
            pull_request.repository, pull_request.number
        ));
    }
    let session_worktrees = load_session_worktrees_async(std::slice::from_ref(&item), db).await?;
    let workspace = db.load_policy_workspace().await?;
    let policy = workspace.as_ref().and_then(|workspace| {
        workspace
            .active_live_canvas()
            .map(|(canvas, document)| (canvas.id.as_str(), document))
    });
    let workflow = automate_item_with_database_policy(DatabaseAutomationRequest {
        policy,
        config: &config,
        project_dir: execution
            .snapshot
            .read_only_run_context
            .as_ref()
            .map(|context| context.worktree.as_str()),
        dry_run: false,
        item: &item,
        session_worktrees: &session_worktrees,
        client: &client,
        host_id: "task-board-write-workflow",
    })
    .await;
    if let Some(error) = workflow.last_error.as_deref() {
        return Err(CliErrorKind::workflow_io(format!(
            "write workflow publication failed: {error}"
        ))
        .into());
    }
    let number = publication_number(workflow.pr_number, execution)?;
    let pull_request = client.get_pull_request(&config, number).await?;
    validate_published_head(&pull_request.head_sha, execution)?;
    Ok(TaskBoardLifecycleOutcome {
        mutated: true,
        terminal: false,
        provider_revision: execution.snapshot.provider_revision.clone(),
        external_url: pull_request
            .html_url
            .or_else(|| Some(format!("https://github.com/{repository}/pull/{number}"))),
    })
}

pub(crate) async fn verify_task_board_write_execution_publication(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    known_external_url: Option<&str>,
) -> Result<TaskBoardLifecycleOutcome, CliError> {
    let (config, client, repository) = write_publication_client(db, execution).await?;
    let number = known_publication_number(execution, known_external_url, &repository)?;
    let pull_request = client.get_pull_request(&config, number).await?;
    validate_published_head(&pull_request.head_sha, execution)?;
    Ok(TaskBoardLifecycleOutcome {
        mutated: false,
        terminal: false,
        provider_revision: execution.snapshot.provider_revision.clone(),
        external_url: pull_request
            .html_url
            .or_else(|| Some(format!("https://github.com/{repository}/pull/{number}"))),
    })
}

async fn write_publication_client(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<(GitHubProjectConfig, GitHubApiAutomationClient, String), CliError> {
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    let configuration_revision = u64::try_from(settings.row_revision)
        .map_err(|_| CliErrorKind::invalid_transition("settings revision is out of range"))?;
    if configuration_revision != execution.snapshot.configuration_revision
        || settings.settings.policy_version != execution.snapshot.policy_version
    {
        return Err(CliErrorKind::concurrent_modification(
            "write publication settings changed after side-effect claim",
        )
        .into());
    }
    let Some((config, token)) = automation_config(&settings.settings) else {
        return Err(CliErrorKind::workflow_io(
            "write workflow publication requires configured GitHub automation",
        )
        .into());
    };
    let repository = config.repository_slug();
    validate_write_publication(execution, &repository)?;
    let mut runtime_config = db.task_board_runtime_config().await?;
    overlay_task_board_git_runtime_secrets(&mut runtime_config);
    let client = GitHubApiAutomationClient::new_with_runtime_config(&token, runtime_config)?;
    Ok((config, client, repository))
}

fn validate_write_publication(
    execution: &TaskBoardWorkflowExecutionRecord,
    repository: &str,
) -> Result<(), CliError> {
    if !matches!(
        execution.snapshot.workflow_kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    ) {
        return Err(CliErrorKind::invalid_transition(
            "write publication requires a DefaultTask or PrFix execution",
        )
        .into());
    }
    if execution.snapshot.execution_repository.as_deref() != Some(repository) {
        return Err(CliErrorKind::invalid_transition(
            "write workflow repository does not match GitHub publication configuration",
        )
        .into());
    }
    if execution
        .transition
        .pull_request
        .as_ref()
        .is_some_and(|pull_request| pull_request.repository != repository)
    {
        return Err(CliErrorKind::invalid_transition(
            "write workflow pull request does not match its frozen repository",
        )
        .into());
    }
    Ok(())
}

fn publication_number(
    workflow_pr_number: Option<u64>,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<u64, CliError> {
    if let (Some(workflow), Some(frozen)) = (
        workflow_pr_number,
        execution.transition.pull_request.as_ref(),
    ) && workflow != frozen.number
    {
        return Err(CliErrorKind::invalid_transition(
            "write workflow publication changed its frozen pull request",
        )
        .into());
    }
    workflow_pr_number
        .or_else(|| {
            execution
                .transition
                .pull_request
                .as_ref()
                .map(|pr| pr.number)
        })
        .ok_or_else(|| {
            CliErrorKind::workflow_io("write workflow publication did not produce a pull request")
                .into()
        })
}

fn known_publication_number(
    execution: &TaskBoardWorkflowExecutionRecord,
    known_external_url: Option<&str>,
    repository: &str,
) -> Result<u64, CliError> {
    let observed = known_external_url.map(parse_publication_url).transpose()?;
    if observed
        .as_ref()
        .is_some_and(|(observed_repository, _)| observed_repository != repository)
    {
        return Err(CliErrorKind::invalid_transition(
            "write workflow publication URL changed its frozen repository",
        )
        .into());
    }
    let observed_number = observed.map(|(_, number)| number);
    reconcile_publication_number(
        observed_number,
        execution
            .transition
            .pull_request
            .as_ref()
            .map(|pr| pr.number),
    )
}

fn reconcile_publication_number(
    observed_number: Option<u64>,
    frozen_number: Option<u64>,
) -> Result<u64, CliError> {
    match (observed_number, frozen_number) {
        (Some(observed), Some(frozen)) if observed != frozen => {
            Err(CliErrorKind::invalid_transition(
                "write workflow publication changed its frozen pull request",
            )
            .into())
        }
        (Some(observed), _) => Ok(observed),
        (None, Some(frozen)) => Ok(frozen),
        (None, None) => Err(CliErrorKind::workflow_io(
            "write workflow publication identity is unavailable after an ambiguous outcome",
        )
        .into()),
    }
}

fn parse_publication_url(url: &str) -> Result<(String, u64), CliError> {
    let path = url.strip_prefix("https://github.com/").ok_or_else(|| {
        CliErrorKind::invalid_transition("publication URL is not canonical GitHub")
    })?;
    let (repository, number) = path
        .split_once("/pull/")
        .ok_or_else(|| CliErrorKind::invalid_transition("publication URL has no pull request"))?;
    let repository = normalize_repository_slug(Some(repository))
        .ok_or_else(|| CliErrorKind::invalid_transition("publication repository is invalid"))?;
    let number = number
        .parse::<u64>()
        .ok()
        .filter(|number| *number > 0)
        .ok_or_else(|| CliErrorKind::invalid_transition("publication pull request is invalid"))?;
    Ok((repository, number))
}

fn validate_published_head(
    actual_head: &str,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    let expected_head = execution
        .transition
        .exact_head_revision
        .as_deref()
        .ok_or_else(|| {
            CliErrorKind::invalid_transition("write workflow publication has no frozen head")
        })?;
    if actual_head != expected_head {
        return Err(CliErrorKind::invalid_transition(format!(
            "published pull request head '{actual_head}' does not match frozen head '{expected_head}'",
        ))
        .into());
    }
    Ok(())
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
