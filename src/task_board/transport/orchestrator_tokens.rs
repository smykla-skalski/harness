use std::env;

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TaskBoardGitHubRepositoryToken, TaskBoardGitHubTokensSyncRequest, normalize_repository_slug,
};

use super::{daemon_client, print_json};

#[derive(Debug, Clone, Args)]
pub struct TaskBoardOrchestratorGithubTokensArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub clear: bool,
    #[arg(long)]
    pub global_token_env: Option<String>,
    #[arg(long)]
    pub repository_token_env: Vec<String>,
}

impl Execute for TaskBoardOrchestratorGithubTokensArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        if !self.clear && self.global_token_env.is_none() && self.repository_token_env.is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "provide --clear, --global-token-env, or --repository-token-env",
            )
            .into());
        }
        let request = self.sync_request()?;
        let response = daemon_client()?.sync_task_board_github_tokens(&request)?;
        if self.json {
            print_json(&response)?;
        } else {
            println!(
                "task-board github tokens: global_configured={}, repository_count={}",
                response.global_token_configured, response.repository_token_count
            );
        }
        Ok(0)
    }
}

impl TaskBoardOrchestratorGithubTokensArgs {
    fn sync_request(&self) -> Result<TaskBoardGitHubTokensSyncRequest, CliError> {
        if self.clear {
            return Ok(TaskBoardGitHubTokensSyncRequest::default());
        }
        Ok(TaskBoardGitHubTokensSyncRequest {
            global_token: self
                .global_token_env
                .as_deref()
                .map(read_secret_env)
                .transpose()?,
            repository_tokens: self
                .repository_token_env
                .iter()
                .map(|value| repository_token_from_env(value))
                .collect::<Result<Vec<_>, _>>()?,
        })
    }
}

fn read_secret_env(name: &str) -> Result<String, CliError> {
    let value = env::var(name).map_err(|_| {
        CliErrorKind::workflow_parse(format!("environment variable '{name}' is not set"))
    })?;
    if value.trim().is_empty() {
        return Err(CliErrorKind::workflow_parse(format!(
            "environment variable '{name}' is empty"
        ))
        .into());
    }
    Ok(value)
}

fn repository_token_from_env(value: &str) -> Result<TaskBoardGitHubRepositoryToken, CliError> {
    let (repository, env_name) = value.split_once('=').ok_or_else(|| {
        CliErrorKind::workflow_parse("repository token env must be owner/repo=ENV_VAR")
    })?;
    let repository = normalize_repository_slug(Some(repository)).ok_or_else(|| {
        CliErrorKind::workflow_parse(format!(
            "invalid task-board repository token override '{repository}', expected owner/repo"
        ))
    })?;
    Ok(TaskBoardGitHubRepositoryToken {
        repository,
        token: read_secret_env(env_name.trim())?,
    })
}

#[cfg(test)]
mod tests {
    use crate::app::command_context::Execute;

    use super::*;

    #[test]
    fn github_token_sync_request_reads_env_and_clear_has_no_token() {
        temp_env::with_var("HARNESS_TEST_GITHUB_TOKEN", Some("github-token"), || {
            let request = TaskBoardOrchestratorGithubTokensArgs {
                json: true,
                clear: false,
                global_token_env: Some("HARNESS_TEST_GITHUB_TOKEN".into()),
                repository_token_env: Vec::new(),
            }
            .sync_request()
            .expect("sync request");
            assert_eq!(request.global_token.as_deref(), Some("github-token"));
        });

        let request = TaskBoardOrchestratorGithubTokensArgs {
            json: true,
            clear: true,
            global_token_env: None,
            repository_token_env: Vec::new(),
        }
        .sync_request()
        .expect("clear request");
        assert!(request.global_token.is_none());
    }

    #[test]
    fn github_token_sync_requires_env_or_clear() {
        let error = TaskBoardOrchestratorGithubTokensArgs {
            json: false,
            clear: false,
            global_token_env: None,
            repository_token_env: Vec::new(),
        }
        .execute(&AppContext)
        .expect_err("missing token source should fail");

        assert!(
            error
                .to_string()
                .contains("provide --clear, --global-token-env, or --repository-token-env")
        );
    }
}
