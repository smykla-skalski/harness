use std::fmt::Display;
use std::path::Path;

use git2::{
    BranchType, Config as Git2Config, CredentialType, PushOptions, RemoteCallbacks,
    Repository as Git2Repository, build::CheckoutBuilder,
};
use tokio::task::spawn_blocking;

use crate::errors::{CliError, CliErrorKind};
use crate::git::GitRepository;
use crate::sandbox;
use crate::task_board::github::GitHubProjectConfig;
use crate::task_board::{TaskBoardGitRuntimeProfile, TaskBoardGitSigningMode};

use crate::daemon::service::task_board_runtime::git_runtime_profile_for_repository;

pub(in crate::daemon::service::task_board_github) struct BranchPublication {
    pub remote: String,
    pub needs_push: bool,
    pub waiting_for_commits: bool,
}

pub(in crate::daemon::service::task_board_github) async fn branch_publication_async(
    worktree: String,
    config: GitHubProjectConfig,
    branch: String,
) -> Result<BranchPublication, CliError> {
    spawn_blocking(move || branch_publication(&worktree, &config, &branch))
        .await
        .unwrap_or_else(|error| {
            Err(CliErrorKind::workflow_io(format!(
                "task-board github branch publication worker failed: {error}"
            ))
            .into())
        })
}

pub(in crate::daemon::service::task_board_github) async fn push_branch_async(
    worktree: String,
    remote: String,
    branch: String,
    github_token: Option<String>,
) -> Result<(), CliError> {
    spawn_blocking(move || push_branch(&worktree, &remote, &branch, github_token.as_deref()))
        .await
        .unwrap_or_else(|error| {
            Err(
                CliErrorKind::workflow_io(format!("task-board github push worker failed: {error}"))
                    .into(),
            )
        })
}

fn branch_publication(
    worktree: &str,
    config: &GitHubProjectConfig,
    branch: &str,
) -> Result<BranchPublication, CliError> {
    let worktree_scope = sandbox::resolve_project_input(worktree)?;
    let repository = GitRepository::discover(worktree_scope.path())
        .map_err(|error| CliErrorKind::workflow_io(error.to_string()))?;
    let remote = repository
        .current_branch_remote_name()
        .map_err(|error| CliErrorKind::workflow_io(error.to_string()))?
        .or_else(|| {
            repository
                .remote_names()
                .ok()
                .and_then(|remotes| remotes.into_iter().find(|remote| remote == "origin"))
        })
        .or_else(|| {
            repository
                .remote_names()
                .ok()
                .and_then(|mut remotes| remotes.pop())
        })
        .ok_or_else(|| CliErrorKind::workflow_io("task-board github remote missing"))?;
    let repo = open_git2_repository(worktree_scope.path())?;
    let remote_url = repo
        .find_remote(&remote)
        .ok()
        .and_then(|remote| remote.url().map(ToOwned::to_owned));
    let git_profile = resolve_git_runtime_profile(git_runtime_profile_for_repository(
        remote_url.as_deref().and_then(parse_github_remote_url),
    )?)?;
    apply_git_runtime_profile(&repo, git_profile.profile())?;
    ensure_local_branch_checked_out(&repo, branch)?;
    let head_target = git2_head_target(&repo, "read HEAD commit for branch publication")?;
    let remote_branch_ref = format!("refs/remotes/{remote}/{branch}");
    if repo.find_reference(&remote_branch_ref).is_ok() {
        let remote_target = git2_reference_target(
            &repo,
            &remote_branch_ref,
            "read remote branch for publication state",
        )?;
        let (ahead, _) = repo
            .graph_ahead_behind(head_target, remote_target)
            .map_err(|error| git_operation_error("compute branch ahead/behind state", error))?;
        return Ok(BranchPublication {
            remote,
            needs_push: ahead > 0,
            waiting_for_commits: false,
        });
    }
    let remote_default_branch = format!("refs/remotes/{remote}/{}", config.default_branch);
    let base_target = git2_reference_target(
        &repo,
        &remote_default_branch,
        "read remote default branch for publication state",
    )?;
    let (ahead_of_base, _) = repo
        .graph_ahead_behind(head_target, base_target)
        .map_err(|error| git_operation_error("compute default-branch ahead/behind state", error))?;
    Ok(BranchPublication {
        remote,
        needs_push: ahead_of_base > 0,
        waiting_for_commits: ahead_of_base == 0,
    })
}

fn push_branch(
    worktree: &str,
    remote: &str,
    branch: &str,
    github_token: Option<&str>,
) -> Result<(), CliError> {
    let worktree_scope = sandbox::resolve_project_input(worktree)?;
    let repo = open_git2_repository(worktree_scope.path())?;
    let source_branch = current_branch_name(&repo)?;
    let mut remote_handle = repo
        .find_remote(remote)
        .map_err(|error| git_operation_error(&format!("resolve remote '{remote}'"), error))?;
    let git_profile = resolve_git_runtime_profile(git_runtime_profile_for_repository(
        remote_handle.url().and_then(parse_github_remote_url),
    )?)?;
    apply_git_runtime_profile(&repo, git_profile.profile())?;
    let mut push_options = PushOptions::new();
    push_options.remote_callbacks(git2_remote_callbacks(
        &repo,
        github_token,
        git_profile.profile().ssh_key_path.as_deref(),
    )?);
    let refspec = format!("refs/heads/{source_branch}:refs/heads/{branch}");
    remote_handle
        .push(&[refspec.as_str()], Some(&mut push_options))
        .map_err(|error| {
            git_operation_error(
                &format!("push branch '{branch}' to remote '{remote}'"),
                error,
            )
        })?;
    Ok(())
}

fn git_operation_error(context: &str, error: impl Display) -> CliError {
    CliErrorKind::workflow_io(format!("task-board github {context}: {error}")).into()
}

fn open_git2_repository(worktree: &Path) -> Result<Git2Repository, CliError> {
    Git2Repository::open(worktree).map_err(|error| {
        git_operation_error(&format!("open repository at {}", worktree.display()), error)
    })
}

struct ResolvedGitRuntimeProfile {
    profile: TaskBoardGitRuntimeProfile,
    _ssh_key_scope: Option<sandbox::ProjectInputScope>,
    _signing_ssh_key_scope: Option<sandbox::ProjectInputScope>,
}

impl ResolvedGitRuntimeProfile {
    fn profile(&self) -> &TaskBoardGitRuntimeProfile {
        &self.profile
    }
}

fn resolve_git_runtime_profile(
    mut profile: TaskBoardGitRuntimeProfile,
) -> Result<ResolvedGitRuntimeProfile, CliError> {
    let ssh_key_scope = resolve_optional_path_input(profile.ssh_key_path.as_deref())?;
    if let Some(scope) = ssh_key_scope.as_ref() {
        profile.ssh_key_path = Some(scope.path().to_string_lossy().into_owned());
    }
    let signing_ssh_key_scope = if profile.signing.mode == TaskBoardGitSigningMode::Ssh {
        resolve_optional_path_input(profile.signing.ssh_key_path.as_deref())?
    } else {
        None
    };
    if let Some(scope) = signing_ssh_key_scope.as_ref() {
        profile.signing.ssh_key_path = Some(scope.path().to_string_lossy().into_owned());
    }
    Ok(ResolvedGitRuntimeProfile {
        profile,
        _ssh_key_scope: ssh_key_scope,
        _signing_ssh_key_scope: signing_ssh_key_scope,
    })
}

fn resolve_optional_path_input(
    input: Option<&str>,
) -> Result<Option<sandbox::ProjectInputScope>, CliError> {
    input
        .map(str::trim)
        .filter(|path| !path.is_empty())
        .map(sandbox::resolve_project_input)
        .transpose()
}

fn apply_git_runtime_profile(
    repo: &Git2Repository,
    profile: &TaskBoardGitRuntimeProfile,
) -> Result<(), CliError> {
    let mut config = repo
        .config()
        .map_err(|error| git_operation_error("load git runtime configuration", error))?;
    if let Some(author_name) = profile.author_name.as_deref() {
        config
            .set_str("user.name", author_name)
            .map_err(|error| git_operation_error("configure git author name", error))?;
    }
    if let Some(author_email) = profile.author_email.as_deref() {
        config
            .set_str("user.email", author_email)
            .map_err(|error| git_operation_error("configure git author email", error))?;
    }
    match profile.signing.mode {
        TaskBoardGitSigningMode::None => {}
        TaskBoardGitSigningMode::Ssh => {
            config
                .set_str("gpg.format", "ssh")
                .map_err(|error| git_operation_error("configure ssh signing format", error))?;
            apply_signing_key(&mut config, profile.signing.ssh_key_path.as_deref(), "ssh")?;
        }
        TaskBoardGitSigningMode::Gpg => {
            config
                .set_str("gpg.format", "openpgp")
                .map_err(|error| git_operation_error("configure gpg signing format", error))?;
            apply_signing_key(&mut config, profile.signing.gpg_key_id.as_deref(), "gpg")?;
        }
    }
    Ok(())
}

fn apply_signing_key(
    config: &mut Git2Config,
    signing_key: Option<&str>,
    mode: &str,
) -> Result<(), CliError> {
    let Some(signing_key) = signing_key else {
        return Ok(());
    };
    config
        .set_str("user.signingkey", signing_key)
        .map_err(|error| git_operation_error(&format!("configure {mode} signing key"), error))?;
    config
        .set_bool("commit.gpgsign", true)
        .map_err(|error| git_operation_error("enable commit signing", error))?;
    Ok(())
}

fn ensure_local_branch_checked_out(repo: &Git2Repository, branch: &str) -> Result<(), CliError> {
    if repo
        .head()
        .ok()
        .and_then(|head| head.shorthand().map(ToOwned::to_owned))
        .as_deref()
        == Some(branch)
    {
        return Ok(());
    }
    if repo.find_branch(branch, BranchType::Local).is_err() {
        let head = repo
            .head()
            .map_err(|error| git_operation_error("read HEAD before branch checkout", error))?;
        let commit = head.peel_to_commit().map_err(|error| {
            git_operation_error("read HEAD commit before branch checkout", error)
        })?;
        repo.branch(branch, &commit, false).map_err(|error| {
            git_operation_error(&format!("create local branch '{branch}'"), error)
        })?;
    }
    let branch_ref = format!("refs/heads/{branch}");
    repo.set_head(&branch_ref).map_err(|error| {
        git_operation_error(&format!("checkout local branch '{branch}'"), error)
    })?;
    let mut checkout = CheckoutBuilder::new();
    checkout.safe();
    repo.checkout_head(Some(&mut checkout)).map_err(|error| {
        git_operation_error(&format!("update worktree for branch '{branch}'"), error)
    })?;
    Ok(())
}

fn git2_head_target(repo: &Git2Repository, context: &str) -> Result<git2::Oid, CliError> {
    repo.head()
        .map_err(|error| git_operation_error(context, error))?
        .target()
        .ok_or_else(|| git_operation_error(context, "HEAD does not point to a direct commit"))
}

fn git2_reference_target(
    repo: &Git2Repository,
    reference: &str,
    context: &str,
) -> Result<git2::Oid, CliError> {
    repo.find_reference(reference)
        .map_err(|error| git_operation_error(context, error))?
        .target()
        .ok_or_else(|| {
            git_operation_error(
                context,
                format!("{reference} does not point to a direct commit"),
            )
        })
}

fn current_branch_name(repo: &Git2Repository) -> Result<String, CliError> {
    repo.head()
        .map_err(|error| git_operation_error("read HEAD for branch name", error))?
        .shorthand()
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            git_operation_error(
                "read HEAD for branch name",
                "detached HEAD is not supported",
            )
        })
}

fn git2_remote_callbacks(
    repo: &Git2Repository,
    github_token: Option<&str>,
    ssh_key_path: Option<&str>,
) -> Result<RemoteCallbacks<'static>, CliError> {
    let config = repo
        .config()
        .map_err(|error| git_operation_error("load git configuration", error))?;
    let token = github_token.map(ToOwned::to_owned);
    let ssh_key_path = ssh_key_path
        .map(str::trim)
        .filter(|path| !path.is_empty())
        .map(ToOwned::to_owned);
    let mut callbacks = RemoteCallbacks::new();
    callbacks.credentials(move |url, username_from_url, allowed_types| {
        if let Some(token) = token.as_deref()
            && allowed_types.contains(CredentialType::USER_PASS_PLAINTEXT)
        {
            return git2::Cred::userpass_plaintext(
                username_from_url.unwrap_or("x-access-token"),
                token,
            );
        }
        if let Some(ssh_key_path) = ssh_key_path.as_deref()
            && allowed_types.contains(CredentialType::SSH_KEY)
            && let Some(username) = username_from_url
        {
            return git2::Cred::ssh_key(username, None, Path::new(ssh_key_path), None);
        }
        git2::Cred::credential_helper(&config, url, username_from_url).or_else(|_| {
            match username_from_url {
                Some(username) if allowed_types.contains(CredentialType::SSH_KEY) => {
                    git2::Cred::ssh_key_from_agent(username)
                }
                _ => Err(git2::Error::from_str(
                    "no supported git credentials available",
                )),
            }
        })
    });
    Ok(callbacks)
}

fn parse_github_remote_url(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    trimmed
        .strip_prefix("git@github.com:")
        .or_else(|| trimmed.strip_prefix("ssh://git@github.com/"))
        .or_else(|| trimmed.strip_prefix("https://github.com/"))
        .or_else(|| trimmed.strip_prefix("http://github.com/"))
        .map(|repository| repository.trim_end_matches(".git"))
}
