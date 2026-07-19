use std::path::Path;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::state::overlay_task_board_git_runtime_secrets;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::github::{
    GitHubApiAutomationClient, GitHubAutomationClient, GitHubProjectConfig,
};
use crate::task_board::{
    PolicyAction, PolicyGraph, TaskBoardItem, TaskBoardLifecycleOutcome,
    TaskBoardOrchestratorSettings, TaskBoardPullRequestHeadIdentity, TaskBoardPullRequestIdentity,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind, normalize_repository_slug,
};

use super::DatabaseAutomationRequest;
use super::support::{
    AutomationPolicy, action_policy, automation_config, github_token_for_repository,
    load_session_worktrees_async, managed_branch_name,
};
use super::workflow::automate_item_with_database_policy;

#[path = "write_publication/evidence.rs"]
mod evidence;
#[path = "write_publication/preparation.rs"]
mod preparation;

use evidence::{
    LocalHeadEvidence, freeze_pull_request, implementation_base, known_publication_number,
    local_head_evidence, required_branch_state, required_frozen_head,
    validate_publication_repository, validate_published_evidence, validate_published_pull_request,
    validate_pull_request_target, worktree_path,
};
#[cfg(test)]
pub(super) use evidence::{parse_publication_url, reconcile_publication_number};
pub(super) use preparation::{
    default_publication_result, prepare_default_publication_item, validate_publication_automations,
};

const WRITE_PUBLICATION_HOST: &str = "task-board-write-workflow";

struct PublicationClient {
    config: GitHubProjectConfig,
    client: GitHubApiAutomationClient,
    repository: String,
}

pub(crate) async fn validate_write_workflow_launch_publication(
    db: &AsyncDaemonDb,
    settings: &TaskBoardOrchestratorSettings,
    workflow_kind: TaskBoardWorkflowKind,
    execution_repository: Option<&str>,
    pull_request: Option<&TaskBoardPullRequestIdentity>,
) -> Result<Option<TaskBoardPullRequestIdentity>, CliError> {
    let publication =
        configured_publication_client(db, settings, workflow_kind, execution_repository).await?;
    let Some(expected) = pull_request else {
        return Ok(None);
    };
    if expected.repository != publication.repository {
        return Err(invalid_transition(
            "write workflow pull request does not match its publication repository",
        ));
    }
    let handle = publication
        .client
        .get_pull_request_fresh(&publication.config, expected.number)
        .await?;
    let frozen = freeze_pull_request(&publication.repository, &handle)?;
    if frozen.repository != expected.repository || frozen.number != expected.number {
        return Err(invalid_transition(
            "write workflow pull request identity changed before launch",
        ));
    }
    let head = required_frozen_head(&frozen)?;
    repository_publication_client(db, &publication.config, &head.repository).await?;
    Ok(Some(frozen))
}

pub(crate) async fn publish_task_board_write_execution(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<TaskBoardLifecycleOutcome, CliError> {
    let publication = write_publication_client(db, execution).await?;
    let local = local_head_evidence(execution).await?;
    let (number, mutated) = match execution.snapshot.workflow_kind {
        TaskBoardWorkflowKind::PrFix => publish_pr_fix(db, execution, &publication, &local).await?,
        TaskBoardWorkflowKind::DefaultTask => {
            publish_default_task(db, execution, &publication, &local).await?
        }
        _ => {
            return Err(invalid_transition(
                "write publication requires a DefaultTask or PrFix execution",
            ));
        }
    };
    Ok(TaskBoardLifecycleOutcome {
        mutated,
        terminal: false,
        provider_revision: execution.snapshot.provider_revision.clone(),
        external_url: Some(format!(
            "https://github.com/{}/pull/{number}",
            publication.repository
        )),
    })
}

pub(crate) async fn verify_task_board_write_execution_publication(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    known_external_url: Option<&str>,
) -> Result<TaskBoardLifecycleOutcome, CliError> {
    let publication = write_publication_client(db, execution).await?;
    let number = known_publication_number(
        execution,
        known_external_url,
        publication.repository.as_str(),
    )?;
    let local = local_head_evidence(execution).await?;
    verify_published(db, execution, &publication, number, &local).await
}

async fn publish_pr_fix(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    publication: &PublicationClient,
    local: &LocalHeadEvidence,
) -> Result<(u64, bool), CliError> {
    let identity = execution
        .transition
        .pull_request
        .as_ref()
        .ok_or_else(|| invalid_transition("PrFix publication has no frozen pull request"))?;
    let head = required_frozen_head(identity)?;
    let handle = publication
        .client
        .get_pull_request_fresh(&publication.config, identity.number)
        .await?;
    validate_pull_request_target(&handle, identity, head)?;
    if handle.head_sha != head.revision {
        return Err(invalid_transition(
            "PrFix pull request head changed before publication",
        ));
    }
    let head_publication =
        repository_publication_client(db, &publication.config, &head.repository).await?;
    let item = db.task_board_item(&execution.item_id).await?;
    let workspace = db.load_policy_workspace().await?;
    let policy = workspace.as_ref().and_then(|workspace| {
        workspace
            .active_live_canvas()
            .map(|(canvas, document)| (canvas.id.as_str(), document))
    });
    let mutated = publish_pr_fix_branch(PrFixBranchRequest {
        client: &head_publication.client,
        config: &head_publication.config,
        worktree: worktree_path(execution)?,
        head,
        item: &item,
        policy,
        pull_request: identity.number,
        reviewed_tree: &local.tree,
    })
    .await?;
    Ok((identity.number, mutated))
}

pub(super) struct PrFixBranchRequest<'a> {
    pub(super) client: &'a dyn GitHubAutomationClient,
    pub(super) config: &'a GitHubProjectConfig,
    pub(super) worktree: &'a Path,
    pub(super) head: &'a TaskBoardPullRequestHeadIdentity,
    pub(super) item: &'a TaskBoardItem,
    pub(super) policy: Option<(&'a str, &'a PolicyGraph)>,
    pub(super) pull_request: u64,
    pub(super) reviewed_tree: &'a str,
}

pub(super) async fn publish_pr_fix_branch(
    request: PrFixBranchRequest<'_>,
) -> Result<bool, CliError> {
    let PrFixBranchRequest {
        client,
        config,
        worktree,
        head,
        item,
        policy,
        pull_request,
        reviewed_tree,
    } = request;
    let before = required_branch_state(client, config, &head.branch).await?;
    if before.commit_sha != head.revision {
        return Err(invalid_transition(
            "PrFix head branch changed before publication",
        ));
    }
    validate_publication_automations(config, TaskBoardWorkflowKind::PrFix)?;
    let mut policy_item = item.clone();
    policy_item.project_id = Some(head.repository.clone());
    let decision = action_policy(
        AutomationPolicy::Database(policy),
        &policy_item,
        PolicyAction::PushBranch,
        Some(&head.branch),
        Some(pull_request),
        None,
    );
    if !decision.is_allow() {
        return Err(invalid_transition(format!(
            "policy blocked PushBranch: {decision:?}"
        )));
    }
    let mutated = before.tree_sha != reviewed_tree;
    client
        .publish_branch_from_worktree_at_parent(
            config,
            worktree,
            &head.branch,
            Some(&before.commit_sha),
        )
        .await?;
    Ok(mutated)
}

async fn publish_default_task(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    publication: &PublicationClient,
    local: &LocalHeadEvidence,
) -> Result<(u64, bool), CliError> {
    let branch = managed_branch_name(
        &publication.config,
        &execution.item_id,
        WRITE_PUBLICATION_HOST,
    );
    let preflight = preflight_default_branch(execution, publication, local, &branch).await?;
    let item = prepare_default_publication_item(
        db.task_board_item(&execution.item_id).await?,
        &publication.repository,
        worktree_path(execution)?,
    )?;
    let session_worktrees = load_session_worktrees_async(std::slice::from_ref(&item), db).await?;
    let workspace = db.load_policy_workspace().await?;
    let policy = workspace.as_ref().and_then(|workspace| {
        workspace
            .active_live_canvas()
            .map(|(canvas, document)| (canvas.id.as_str(), document))
    });
    let project_dir = worktree_path(execution)?
        .to_str()
        .ok_or_else(|| invalid_transition("write publication worktree is not valid UTF-8"))?;
    let workflow = automate_item_with_database_policy(DatabaseAutomationRequest {
        policy,
        config: &publication.config,
        project_dir: Some(project_dir),
        dry_run: false,
        item: &item,
        session_worktrees: &session_worktrees,
        client: &publication.client,
        host_id: WRITE_PUBLICATION_HOST,
        expected_parent: Some(&preflight.expected_parent),
    })
    .await;
    default_publication_result(
        &workflow,
        execution
            .transition
            .pull_request
            .as_ref()
            .map(|pull_request| pull_request.number),
        preflight.mutated,
    )
}

struct DefaultBranchPreflight {
    mutated: bool,
    expected_parent: String,
}

async fn preflight_default_branch(
    execution: &TaskBoardWorkflowExecutionRecord,
    publication: &PublicationClient,
    local: &LocalHeadEvidence,
    branch: &str,
) -> Result<DefaultBranchPreflight, CliError> {
    let base = implementation_base(execution)?;
    let branch_state = publication
        .client
        .get_branch_state(&publication.config, branch)
        .await?;
    if let Some(branch_state) = branch_state {
        if branch_state.commit_sha != base {
            return Err(invalid_transition(
                "managed publication branch changed from the implementation base",
            ));
        }
        return Ok(DefaultBranchPreflight {
            mutated: branch_state.tree_sha != local.tree,
            expected_parent: branch_state.commit_sha,
        });
    }
    let default = required_branch_state(
        &publication.client,
        &publication.config,
        &publication.config.default_branch,
    )
    .await?;
    if default.commit_sha != base {
        return Err(invalid_transition(
            "publication base branch changed after implementation started",
        ));
    }
    Ok(DefaultBranchPreflight {
        mutated: true,
        expected_parent: default.commit_sha,
    })
}

async fn verify_published(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    publication: &PublicationClient,
    number: u64,
    local: &LocalHeadEvidence,
) -> Result<TaskBoardLifecycleOutcome, CliError> {
    let handle = publication
        .client
        .get_pull_request_fresh(&publication.config, number)
        .await?;
    let expected =
        expected_publication_target(execution, &publication.config, number, &handle.head_sha)?;
    let head = required_frozen_head(&expected)?;
    if !validate_published_pull_request(&handle, &expected, head)? {
        let head_publication =
            repository_publication_client(db, &publication.config, &head.repository).await?;
        let branch = required_branch_state(
            &head_publication.client,
            &head_publication.config,
            &head.branch,
        )
        .await?;
        validate_published_evidence(&handle, &expected, head, &branch, local)?;
    }
    Ok(TaskBoardLifecycleOutcome {
        mutated: false,
        terminal: false,
        provider_revision: execution.snapshot.provider_revision.clone(),
        external_url: handle.html_url.or_else(|| {
            Some(format!(
                "https://github.com/{}/pull/{number}",
                publication.repository
            ))
        }),
    })
}

fn expected_publication_target(
    execution: &TaskBoardWorkflowExecutionRecord,
    config: &GitHubProjectConfig,
    number: u64,
    observed_head: &str,
) -> Result<TaskBoardPullRequestIdentity, CliError> {
    if execution.snapshot.workflow_kind == TaskBoardWorkflowKind::PrFix {
        return execution
            .transition
            .pull_request
            .clone()
            .ok_or_else(|| invalid_transition("PrFix publication has no frozen pull request"));
    }
    Ok(TaskBoardPullRequestIdentity {
        repository: config.repository_slug(),
        number,
        head: Some(TaskBoardPullRequestHeadIdentity {
            repository: config.repository_slug(),
            branch: managed_branch_name(config, &execution.item_id, WRITE_PUBLICATION_HOST),
            revision: observed_head.into(),
        }),
    })
}

async fn write_publication_client(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<PublicationClient, CliError> {
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    let configuration_revision = u64::try_from(settings.row_revision)
        .map_err(|_| invalid_transition("settings revision is out of range"))?;
    if configuration_revision != execution.snapshot.configuration_revision
        || settings.settings.policy_version != execution.snapshot.policy_version
    {
        return Err(CliErrorKind::concurrent_modification(
            "write publication settings changed after side-effect claim",
        )
        .into());
    }
    validate_write_publication(execution)?;
    configured_publication_client(
        db,
        &settings.settings,
        execution.snapshot.workflow_kind,
        execution.snapshot.execution_repository.as_deref(),
    )
    .await
}

async fn configured_publication_client(
    db: &AsyncDaemonDb,
    settings: &TaskBoardOrchestratorSettings,
    workflow_kind: TaskBoardWorkflowKind,
    execution_repository: Option<&str>,
) -> Result<PublicationClient, CliError> {
    let Some((config, token)) = automation_config(settings) else {
        return Err(CliErrorKind::workflow_io(
            "write workflow publication requires configured GitHub automation",
        )
        .into());
    };
    validate_publication_automations(&config, workflow_kind)?;
    let repository = config.repository_slug();
    validate_publication_repository(execution_repository, &repository)?;
    let mut runtime_config = db.task_board_runtime_config().await?;
    overlay_task_board_git_runtime_secrets(&mut runtime_config);
    let client = GitHubApiAutomationClient::new_with_runtime_config(token, runtime_config)?;
    Ok(PublicationClient {
        config,
        client,
        repository,
    })
}

async fn repository_publication_client(
    db: &AsyncDaemonDb,
    base: &GitHubProjectConfig,
    repository: &str,
) -> Result<PublicationClient, CliError> {
    let repository = normalize_repository_slug(Some(repository))
        .ok_or_else(|| invalid_transition("publication head repository is invalid"))?;
    let token = github_token_for_repository(Some(&repository)).ok_or_else(|| {
        CliErrorKind::workflow_io(format!(
            "write workflow publication has no GitHub token for '{repository}'"
        ))
    })?;
    let (owner, repo) = repository
        .split_once('/')
        .ok_or_else(|| invalid_transition("publication head repository is invalid"))?;
    let mut config = base.clone();
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

fn validate_write_publication(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    if !matches!(
        execution.snapshot.workflow_kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    ) {
        return Err(invalid_transition(
            "write publication requires a DefaultTask or PrFix execution",
        ));
    }
    if execution
        .transition
        .pull_request
        .as_ref()
        .is_some_and(|pull_request| {
            execution.snapshot.execution_repository.as_deref()
                != Some(pull_request.repository.as_str())
        })
    {
        return Err(invalid_transition(
            "write workflow pull request does not match its frozen repository",
        ));
    }
    if execution.snapshot.workflow_kind == TaskBoardWorkflowKind::PrFix {
        required_frozen_head(
            execution.transition.pull_request.as_ref().ok_or_else(|| {
                invalid_transition("PrFix publication has no frozen pull request")
            })?,
        )?;
    }
    Ok(())
}

fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}
