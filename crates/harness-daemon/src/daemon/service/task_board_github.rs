use std::collections::BTreeMap;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::reviews_store::PolicyGraphQueries;
use crate::daemon::state::overlay_task_board_git_runtime_secrets;
use crate::task_board::github::{
    GitHubApiAutomationClient, GitHubAutomationClient, GitHubAutomationSettings,
    GitHubProjectConfig,
};
use crate::task_board::policy_graph::PolicyCanvasWorkspace;
use crate::task_board::{
    PolicyGraph, TaskBoardGitRuntimeConfig, TaskBoardItem, TaskBoardOrchestratorDispatchInput,
    TaskBoardOrchestratorSettings, TaskBoardReadOnlyWorkflowContractError,
    normalize_repository_slug, task_board_read_only_execution_repository,
};
use harness_kernel::errors::CliError;

mod support;
mod workflow;
mod write_publication;

#[cfg(test)]
use write_publication::{
    default_publication_result, parse_publication_url, reconcile_publication_number,
    validate_publication_automations,
};
pub(crate) use write_publication::{
    publish_task_board_write_execution, validate_write_workflow_launch_publication,
    verify_task_board_write_execution_publication,
};

use self::support::{automation_config, github_token_for_repository, load_session_worktrees_async};
use self::workflow::automate_item_with_database_policy;

pub(super) struct DatabaseAutomationRequest<'a> {
    pub policy: Option<(&'a str, &'a PolicyGraph)>,
    pub config: &'a GitHubProjectConfig,
    pub dry_run: bool,
    pub item: &'a TaskBoardItem,
    pub session_worktrees: &'a BTreeMap<String, String>,
    pub client: &'a dyn GitHubAutomationClient,
    pub host_id: &'a str,
    pub expected_parent: Option<&'a str>,
    pub session: Option<&'a super::TaskBoardAutomationRunSession>,
}

pub(crate) async fn run_task_board_github_automation_async(
    settings: &TaskBoardOrchestratorSettings,
    input: &TaskBoardOrchestratorDispatchInput,
    items: &[TaskBoardItem],
    async_db: &AsyncDaemonDb,
    session: Option<&super::TaskBoardAutomationRunSession>,
) -> Result<(), CliError> {
    ensure_active(session).await?;
    let Some(defaults) = automation_config(settings) else {
        return Ok(());
    };
    let prepared = prepare_github_automation(items, async_db).await?;
    ensure_active(session).await?;
    let policy = prepared.workspace.as_ref().and_then(|workspace| {
        workspace
            .active_live_canvas()
            .map(|(canvas, document)| (canvas.id.as_str(), document))
    });
    for (repository, grouped) in group_items_by_repository(items) {
        ensure_active(session).await?;
        run_repository_github_automation(RepositoryGitHubAutomationRequest {
            settings,
            defaults: &defaults,
            input,
            async_db,
            policy,
            repository: &repository,
            items: &grouped,
            session_worktrees: &prepared.session_worktrees,
            runtime_config: &prepared.runtime_config,
            host_id: prepared.host_id.as_str(),
            session,
        })
        .await?;
    }
    Ok(())
}

/// Everything every repository's automation call needs, resolved once so the
/// dispatch loop below carries no await of its own beyond the per-repository
/// call itself.
struct GitHubAutomationPreparation {
    host_id: String,
    session_worktrees: BTreeMap<String, String>,
    workspace: Option<PolicyCanvasWorkspace>,
    runtime_config: TaskBoardGitRuntimeConfig,
}

async fn prepare_github_automation(
    items: &[TaskBoardItem],
    async_db: &AsyncDaemonDb,
) -> Result<GitHubAutomationPreparation, CliError> {
    let host_id = super::task_board_db::task_board_host_local_db(async_db)
        .await?
        .id;
    let session_worktrees = load_session_worktrees_async(items, async_db).await?;
    let workspace = async_db.load_policy_workspace().await?;
    let mut runtime_config = async_db.task_board_runtime_config().await?;
    overlay_task_board_git_runtime_secrets(&mut runtime_config);
    Ok(GitHubAutomationPreparation {
        host_id,
        session_worktrees,
        workspace,
        runtime_config,
    })
}

struct RepositoryGitHubAutomationRequest<'a> {
    settings: &'a TaskBoardOrchestratorSettings,
    defaults: &'a GitHubAutomationSettings,
    input: &'a TaskBoardOrchestratorDispatchInput,
    async_db: &'a AsyncDaemonDb,
    policy: Option<(&'a str, &'a PolicyGraph)>,
    repository: &'a str,
    items: &'a [&'a TaskBoardItem],
    session_worktrees: &'a BTreeMap<String, String>,
    runtime_config: &'a TaskBoardGitRuntimeConfig,
    host_id: &'a str,
    session: Option<&'a super::TaskBoardAutomationRunSession>,
}

/// Publish one repository's items, dropping the repository (`Ok(())`) rather
/// than failing every other one when it has no token, an unusable slug, or no
/// default branch to publish against.
async fn run_repository_github_automation(
    request: RepositoryGitHubAutomationRequest<'_>,
) -> Result<(), CliError> {
    let RepositoryGitHubAutomationRequest {
        settings,
        defaults,
        input,
        async_db,
        policy,
        repository,
        items,
        session_worktrees,
        runtime_config,
        host_id,
        session,
    } = request;
    ensure_active(session).await?;
    let Some(token) = github_token_for_repository(Some(repository)) else {
        log_missing_github_token(repository);
        return Ok(());
    };
    let Some((owner, repo)) = repository.split_once('/') else {
        log_unusable_repository_slug(repository);
        return Ok(());
    };
    let client =
        GitHubApiAutomationClient::new_with_runtime_config(&token, runtime_config.clone())?;
    let Some(branch) = default_branch_for_automation(&client, owner, repo, repository).await?
    else {
        return Ok(());
    };
    ensure_active(session).await?;
    let config =
        repository_conventions(settings, defaults, repository).for_repository(owner, repo, branch);
    run_task_board_github_automation_with_database_client(
        async_db,
        policy,
        &config,
        input,
        items,
        session_worktrees,
        &client,
        host_id,
        session,
    )
    .await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_missing_github_token(repository: &str) {
    tracing::warn!(
        %repository,
        "skipping task-board GitHub automation: no token for this repository"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_unusable_repository_slug(repository: &str) {
    tracing::warn!(
        %repository,
        "skipping task-board GitHub automation: repository is not an owner/name slug"
    );
}

/// Resolve the branch to publish against, dropping the repository
/// (`Ok(None)`) rather than failing every other one when this lookup comes
/// back empty or errors.
async fn default_branch_for_automation(
    client: &GitHubApiAutomationClient,
    owner: &str,
    repo: &str,
    repository: &str,
) -> Result<Option<String>, CliError> {
    match client.repository_default_branch(owner, repo).await {
        // Trimmed, not just checked: a branch name carrying whitespace
        // stamps a ref git will refuse much later, where the failure no
        // longer points here.
        Ok(Some(branch)) if !branch.trim().is_empty() => Ok(Some(branch.trim().to_owned())),
        // One unreachable repository must not stall every other one, but the
        // reason has to reach the log or an auth or network fault is
        // indistinguishable from a repository that simply reports no branch.
        Ok(_) => {
            log_missing_default_branch(repository);
            Ok(None)
        }
        Err(error) => {
            log_default_branch_lookup_failure(repository, &error);
            Ok(None)
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_missing_default_branch(repository: &str) {
    tracing::warn!(
        %repository,
        "skipping task-board GitHub automation: repository reported no default branch"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_default_branch_lookup_failure(repository: &str, error: &CliError) {
    tracing::warn!(
        %repository,
        %error,
        "skipping task-board GitHub automation: default-branch lookup failed"
    );
}

/// The conventions this repository publishes under: the global ones, with any
/// overrides it carries applied. A board fed from work and personal
/// repositories needs different reviewers depending on where a change lands.
///
/// Both slugs are normalized before matching. Publication reaches this function
/// with the repository the item names and canonicalizes it only later, when it
/// builds the client, so a case difference would otherwise drop a repository's
/// overrides and publish under the global answer instead.
pub(super) fn repository_conventions(
    settings: &TaskBoardOrchestratorSettings,
    defaults: &GitHubAutomationSettings,
    repository: &str,
) -> GitHubAutomationSettings {
    let Some(requested) = normalize_repository_slug(Some(repository)) else {
        return defaults.clone();
    };
    settings
        .repositories
        .iter()
        .find(|configured| {
            normalize_repository_slug(Some(&configured.repository))
                .is_some_and(|configured| configured == requested)
        })
        .map_or_else(
            || defaults.clone(),
            |configured| defaults.merged_with(configured),
        )
}

/// Items reach this loop from every repository the board watches, so each group
/// gets its own token and client. An item with no GitHub repository is not ours
/// to publish and drops out silently; one whose repository is unusable is worth
/// saying out loud, because silence here is what let a blank publication target
/// go unnoticed.
fn group_items_by_repository(items: &[TaskBoardItem]) -> BTreeMap<String, Vec<&TaskBoardItem>> {
    let mut grouped: BTreeMap<String, Vec<&TaskBoardItem>> = BTreeMap::new();
    for item in items {
        insert_item_by_repository(&mut grouped, item);
    }
    grouped
}

/// File one item under its repository, or log and drop it (rather than let a
/// blank publication target through unnoticed) when the repository cannot be
/// resolved.
fn insert_item_by_repository<'a>(
    grouped: &mut BTreeMap<String, Vec<&'a TaskBoardItem>>,
    item: &'a TaskBoardItem,
) {
    match task_board_read_only_execution_repository(item) {
        Ok(Some(repository)) => grouped.entry(repository).or_default().push(item),
        Ok(None) => {}
        Err(error) => log_unusable_item_repository(item, &error),
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_unusable_item_repository(
    item: &TaskBoardItem,
    error: &TaskBoardReadOnlyWorkflowContractError,
) {
    tracing::warn!(
        item = %item.id,
        %error,
        "skipping task-board GitHub automation for an item with an unusable repository"
    );
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
    items: &[&TaskBoardItem],
    session_worktrees: &BTreeMap<String, String>,
    client: &dyn GitHubAutomationClient,
    host_id: &str,
    session: Option<&super::TaskBoardAutomationRunSession>,
) -> Result<(), CliError> {
    for item in items {
        ensure_active(session).await?;
        let workflow = automate_item_with_database_policy(DatabaseAutomationRequest {
            policy,
            config,
            item,
            session_worktrees,
            dry_run: input.dry_run,
            client,
            host_id,
            expected_parent: None,
            session,
        })
        .await?;
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

async fn ensure_active(
    session: Option<&super::TaskBoardAutomationRunSession>,
) -> Result<(), CliError> {
    if let Some(session) = session {
        session.ensure_active().await?;
    }
    Ok(())
}

#[cfg(test)]
#[path = "task_board_github/repository_conventions_tests.rs"]
mod repository_conventions_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
#[path = "task_board_github/write_publication_tests.rs"]
mod write_publication_tests;
