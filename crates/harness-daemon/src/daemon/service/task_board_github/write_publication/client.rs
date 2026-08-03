use harness_kernel::errors::{CliError, CliErrorKind};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::state::overlay_task_board_git_runtime_secrets;
use crate::task_board::github::{
    GitHubApiAutomationClient, GitHubAutomationSettings, GitHubProjectConfig,
};
use crate::task_board::{
    TaskBoardOrchestratorSettings, TaskBoardWorkflowKind, normalize_repository_slug,
};

use super::super::repository_conventions;
use super::super::support::{automation_config, github_token_for_repository};
use super::preparation::validate_publication_automations;
use crate::daemon::db::task_board::prelude::*;

/// Stands in for the base branch until the publish path detects the real one.
/// Named rather than spelled "main" inline so a reader hitting it in a debugger
/// sees that nothing chose it.
const DETECTED_LATER_BASE_BRANCH: &str = "main";

pub(in crate::daemon::service::task_board_github) struct PublicationClient {
    pub(in crate::daemon::service::task_board_github) config: GitHubProjectConfig,
    pub(in crate::daemon::service::task_board_github) client: GitHubApiAutomationClient,
    pub(in crate::daemon::service::task_board_github) repository: String,
}

/// Build the publication client for the repository an item belongs to.
///
/// Publication used to target one repository named in settings and reject every
/// item from anywhere else. The board is fed from many repositories, so the item
/// names the target and settings only carry the conventions shared across them.
pub(super) async fn publication_client_for_repository(
    db: &AsyncDaemonDb,
    settings: &TaskBoardOrchestratorSettings,
    workflow_kind: TaskBoardWorkflowKind,
    repository: Option<&str>,
) -> Result<PublicationClient, CliError> {
    let Some(requested) = repository else {
        return Err(CliErrorKind::invalid_transition(
            "write workflow publication has no target repository: link the item to a GitHub issue \
             or set its execution repository",
        )
        .into());
    };
    let Some(config) = automation_config(settings) else {
        return Err(CliErrorKind::workflow_io(
            "write workflow publication requires configured GitHub automation",
        )
        .into());
    };
    // Overrides are applied before the automation check, so a repository that
    // turns an automation off is refused here rather than publishing under the
    // global answer.
    let config = repository_conventions(settings, &config, requested);
    validate_publication_automations(&config.enabled_automations, workflow_kind)?;
    stamp_repository(db, config, requested).await
}

/// Replace the configured base branch with the one the repository actually uses.
///
/// A single configured value cannot be right for a board spanning many
/// repositories, where some branch from `master` and the rest from `main`.
/// Refusing beats guessing: a wrong base branch surfaces much later as an
/// unrelated-looking "branch is not visible" failure.
pub(super) async fn resolve_base_branch(
    publication: &mut PublicationClient,
) -> Result<(), CliError> {
    let detected = publication
        .client
        .repository_default_branch(&publication.config.owner, &publication.config.repo)
        .await?;
    let Some(branch) = detected
        .map(|branch| branch.trim().to_owned())
        .filter(|branch| !branch.is_empty())
    else {
        return Err(CliErrorKind::workflow_io(format!(
            "write workflow publication could not detect the default branch for '{}'",
            publication.repository
        ))
        .into());
    };
    publication.config.default_branch = branch;
    Ok(())
}

/// Build a client for a pull request's head repository, which is a different
/// repository from the base whenever the contribution came from a fork.
pub(super) async fn repository_publication_client(
    db: &AsyncDaemonDb,
    base: &GitHubProjectConfig,
    repository: &str,
) -> Result<PublicationClient, CliError> {
    stamp_repository(db, base.conventions(), repository).await
}

async fn stamp_repository(
    db: &AsyncDaemonDb,
    settings: GitHubAutomationSettings,
    repository: &str,
) -> Result<PublicationClient, CliError> {
    let Some(repository) = normalize_repository_slug(Some(repository)) else {
        return Err(CliErrorKind::invalid_transition(format!(
            "write workflow publication target '{repository}' is not an owner/repo repository"
        ))
        .into());
    };
    let token = github_token_for_repository(Some(&repository)).ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "write workflow publication has no GitHub token for '{repository}': add a global or \
             repository token in Settings > Secrets"
        )))
    })?;
    let (owner, repo) = repository.split_once('/').ok_or_else(|| {
        CliError::from(CliErrorKind::invalid_transition(
            "write workflow publication target is not an owner/repo repository",
        ))
    })?;
    // The base branch is a placeholder until `resolve_base_branch` detects the
    // real one. Only the publish path calls that; launch validation reads the
    // pull request by owner and repo and never looks at the base.
    let config = settings.for_repository(owner, repo, DETECTED_LATER_BASE_BRANCH);
    let mut runtime_config = db.task_board_runtime_config().await?;
    overlay_task_board_git_runtime_secrets(&mut runtime_config);
    let client = GitHubApiAutomationClient::new_with_runtime_config(token, runtime_config)?;
    Ok(PublicationClient {
        config,
        client,
        repository,
    })
}

#[cfg(test)]
#[path = "client_tests.rs"]
mod tests;
