use harness_kernel::errors::{CliError, CliErrorKind};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::state::overlay_task_board_git_runtime_secrets;
use crate::task_board::github::{GitHubApiAutomationClient, GitHubProjectConfig};
use crate::task_board::{
    TaskBoardOrchestratorSettings, TaskBoardWorkflowKind, normalize_repository_slug,
};

use super::super::support::{automation_config, github_token_for_repository};
use super::preparation::validate_publication_automations;

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
    validate_publication_automations(&config, workflow_kind)?;
    stamp_repository(db, config, requested).await
}

/// Replace the configured base branch with the one the repository actually uses.
///
/// A single configured value cannot be right for a board spanning many
/// repositories - `owner/alpha` branches from `master`, `owner/beta` from
/// `main`. Refusing beats guessing: a wrong base branch surfaces much later as
/// an unrelated-looking "branch is not visible" failure.
pub(super) async fn resolve_base_branch(
    publication: &mut PublicationClient,
) -> Result<(), CliError> {
    let detected = publication
        .client
        .repository_default_branch(&publication.config.owner, &publication.config.repo)
        .await?;
    let Some(branch) = detected.filter(|branch| !branch.trim().is_empty()) else {
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
    stamp_repository(db, base.clone(), repository).await
}

async fn stamp_repository(
    db: &AsyncDaemonDb,
    mut config: GitHubProjectConfig,
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
            "write workflow publication has no GitHub token for '{repository}': add a repository \
             token in Settings > Secrets"
        )))
    })?;
    let (owner, repo) = repository.split_once('/').ok_or_else(|| {
        CliError::from(CliErrorKind::invalid_transition(
            "write workflow publication target is not an owner/repo repository",
        ))
    })?;
    config.owner = owner.into();
    config.repo = repo.into();
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
