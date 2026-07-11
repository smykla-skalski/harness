use std::env;

use clap::{Args, Subcommand, ValueEnum};

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::{
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorSettingsUpdateRequest,
};
use crate::daemon::service;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::types::TaskBoardStatus;
use crate::task_board::{
    TaskBoardGitRepositoryOverride, TaskBoardGitRuntimeConfig, TaskBoardGitRuntimeProfile,
    TaskBoardGitSigningConfig, TaskBoardGitSigningMode, TaskBoardOrchestratorStatus,
    normalize_repository_slug,
};

use super::orchestrator_tokens::{
    TaskBoardOrchestratorGithubTokensArgs, TaskBoardOrchestratorTodoistTokenArgs,
};
use super::print_json;

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum TaskBoardOrchestratorCommand {
    /// Print durable orchestrator status.
    Status(TaskBoardOrchestratorJsonArgs),
    /// Enable autonomous orchestration intent.
    Start(TaskBoardOrchestratorJsonArgs),
    /// Disable autonomous orchestration intent.
    Stop(TaskBoardOrchestratorJsonArgs),
    /// Run one orchestrator tick.
    RunOnce(TaskBoardOrchestratorRunOnceArgs),
    /// Read or update durable orchestrator settings.
    Settings(TaskBoardOrchestratorSettingsArgs),
    /// Read or update git runtime config.
    RuntimeConfig(Box<TaskBoardOrchestratorRuntimeConfigArgs>),
    /// Sync process-local GitHub tokens from environment variables.
    GithubTokens(TaskBoardOrchestratorGithubTokensArgs),
    /// Sync the process-local Todoist token from an environment variable.
    TodoistToken(TaskBoardOrchestratorTodoistTokenArgs),
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardOrchestratorJsonArgs {
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardOrchestratorRunOnceArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long, conflicts_with = "apply")]
    pub dry_run: bool,
    #[arg(long)]
    pub apply: bool,
    #[arg(long = "item-id", visible_alias = "id")]
    pub item_id: Option<String>,
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
    #[arg(long)]
    pub project_dir: Option<String>,
    #[arg(long)]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardOrchestratorSettingsArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub dry_run_default: Option<bool>,
    #[arg(long, value_enum)]
    pub dispatch_status_filter: Option<TaskBoardStatus>,
    #[arg(long)]
    pub clear_dispatch_status_filter: bool,
    #[arg(long)]
    pub project_dir: Option<String>,
    #[arg(long)]
    pub clear_project_dir: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardOrchestratorRuntimeConfigArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub repository: Option<String>,
    #[command(flatten)]
    pub identity: TaskBoardRuntimeIdentityArgs,
    #[command(flatten)]
    pub signing: TaskBoardRuntimeSigningArgs,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardRuntimeIdentityArgs {
    #[arg(long)]
    pub author_name: Option<String>,
    #[arg(long)]
    pub clear_author_name: bool,
    #[arg(long)]
    pub author_email: Option<String>,
    #[arg(long)]
    pub clear_author_email: bool,
    #[arg(long)]
    pub ssh_key_path: Option<String>,
    #[arg(long)]
    pub clear_ssh_key_path: bool,
    #[arg(long)]
    pub ssh_private_key_env: Option<String>,
    #[arg(long)]
    pub ssh_private_key_passphrase_env: Option<String>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardRuntimeSigningArgs {
    #[arg(long, value_enum)]
    pub signing_mode: Option<TaskBoardGitSigningModeArg>,
    #[arg(long)]
    pub signing_ssh_key_path: Option<String>,
    #[arg(long)]
    pub signing_ssh_private_key_env: Option<String>,
    #[arg(long)]
    pub signing_ssh_private_key_passphrase_env: Option<String>,
    #[arg(long)]
    pub gpg_key_id: Option<String>,
    #[arg(long)]
    pub gpg_private_key_path: Option<String>,
    #[arg(long)]
    pub gpg_private_key_env: Option<String>,
    #[arg(long)]
    pub gpg_private_key_passphrase_env: Option<String>,
    #[arg(long)]
    pub clear_signing: bool,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
#[value(rename_all = "snake_case")]
pub enum TaskBoardGitSigningModeArg {
    None,
    Ssh,
    Gpg,
}

impl Execute for TaskBoardOrchestratorCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Status(args) => args.execute_status(context),
            Self::Start(args) => args.execute_start(context),
            Self::Stop(args) => args.execute_stop(context),
            Self::RunOnce(args) => args.execute(context),
            Self::Settings(args) => args.execute(context),
            Self::RuntimeConfig(args) => args.execute(context),
            Self::GithubTokens(args) => args.execute(context),
            Self::TodoistToken(args) => args.execute(context),
        }
    }
}

impl TaskBoardOrchestratorJsonArgs {
    fn execute_status(&self, _context: &AppContext) -> Result<i32, CliError> {
        let status = service::task_board_orchestrator_status()?;
        print_status(&status, self.json)
    }

    fn execute_start(&self, _context: &AppContext) -> Result<i32, CliError> {
        let status = service::start_task_board_orchestrator()?;
        print_status(&status, self.json)
    }

    fn execute_stop(&self, _context: &AppContext) -> Result<i32, CliError> {
        let status = service::stop_task_board_orchestrator()?;
        print_status(&status, self.json)
    }
}

impl Execute for TaskBoardOrchestratorRunOnceArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = TaskBoardOrchestratorRunOnceRequest {
            item_id: self.item_id.clone(),
            dry_run: dry_run_override(self.dry_run, self.apply),
            status: self.status,
            project_dir: self.project_dir.clone(),
            actor: self.actor.clone(),
        };
        let status = service::run_task_board_orchestrator_once(&request, None)?;
        print_status(&status, self.json)
    }
}

impl Execute for TaskBoardOrchestratorSettingsArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let settings = if self.has_update() {
            service::update_task_board_orchestrator_settings(&self.update_request())?
        } else {
            service::task_board_orchestrator_settings()?
        };
        if self.json {
            print_json(&settings)?;
        } else {
            println!(
                "task-board orchestrator settings: dry_run_default={}, project_dir={}",
                settings.dry_run_default,
                settings.project_dir.as_deref().unwrap_or("<unset>")
            );
        }
        Ok(0)
    }
}

impl TaskBoardOrchestratorSettingsArgs {
    fn has_update(&self) -> bool {
        self.dry_run_default.is_some()
            || self.dispatch_status_filter.is_some()
            || self.clear_dispatch_status_filter
            || self.project_dir.is_some()
            || self.clear_project_dir
    }

    fn update_request(&self) -> TaskBoardOrchestratorSettingsUpdateRequest {
        TaskBoardOrchestratorSettingsUpdateRequest {
            dry_run_default: self.dry_run_default,
            dispatch_status_filter: self.dispatch_status_filter,
            clear_dispatch_status_filter: self.clear_dispatch_status_filter,
            project_dir: self.project_dir.clone(),
            clear_project_dir: self.clear_project_dir,
            ..TaskBoardOrchestratorSettingsUpdateRequest::default()
        }
    }
}

impl Execute for TaskBoardOrchestratorRuntimeConfigArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let config = if self.has_update() {
            let mut config = service::task_board_git_runtime_config()?;
            self.apply_update(&mut config)?;
            service::update_task_board_git_runtime_config(&config)?
        } else {
            service::task_board_git_runtime_config()?
        };
        if self.json {
            print_json(&config)?;
        } else {
            print_runtime_config_summary(&config);
        }
        Ok(0)
    }
}

impl TaskBoardOrchestratorRuntimeConfigArgs {
    fn has_update(&self) -> bool {
        self.identity.has_update() || self.signing.has_update()
    }

    fn apply_update(&self, config: &mut TaskBoardGitRuntimeConfig) -> Result<(), CliError> {
        if let Some(repository) = &self.repository {
            let repository = normalize_repository_slug(Some(repository)).ok_or_else(|| {
                CliErrorKind::workflow_parse(format!(
                    "invalid task-board repository override '{repository}', expected owner/repo"
                ))
            })?;
            let profile = repository_profile_mut(config, &repository);
            self.apply_profile_update(profile)?;
            return Ok(());
        }
        self.apply_profile_update(&mut config.global)
    }

    fn apply_profile_update(
        &self,
        profile: &mut TaskBoardGitRuntimeProfile,
    ) -> Result<(), CliError> {
        apply_optional_string(
            &mut profile.author_name,
            self.identity.author_name.as_ref(),
            self.identity.clear_author_name,
        );
        apply_optional_string(
            &mut profile.author_email,
            self.identity.author_email.as_ref(),
            self.identity.clear_author_email,
        );
        apply_optional_string(
            &mut profile.ssh_key_path,
            self.identity.ssh_key_path.as_ref(),
            self.identity.clear_ssh_key_path,
        );
        if let Some(name) = &self.identity.ssh_private_key_env {
            profile.ssh_private_key = Some(read_secret_env(name)?);
        }
        if let Some(name) = &self.identity.ssh_private_key_passphrase_env {
            profile.ssh_private_key_passphrase = Some(read_secret_env(name)?);
        }
        self.apply_signing_update(&mut profile.signing)
    }

    fn apply_signing_update(
        &self,
        signing: &mut TaskBoardGitSigningConfig,
    ) -> Result<(), CliError> {
        if self.signing.clear_signing {
            *signing = TaskBoardGitSigningConfig::default();
        }
        if let Some(mode) = self.signing.signing_mode {
            signing.mode = TaskBoardGitSigningMode::from(mode);
        }
        apply_optional_string(
            &mut signing.ssh_key_path,
            self.signing.signing_ssh_key_path.as_ref(),
            false,
        );
        if let Some(name) = &self.signing.signing_ssh_private_key_env {
            signing.ssh_private_key = Some(read_secret_env(name)?);
        }
        if let Some(name) = &self.signing.signing_ssh_private_key_passphrase_env {
            signing.ssh_private_key_passphrase = Some(read_secret_env(name)?);
        }
        apply_optional_string(
            &mut signing.gpg_key_id,
            self.signing.gpg_key_id.as_ref(),
            false,
        );
        apply_optional_string(
            &mut signing.gpg_private_key_path,
            self.signing.gpg_private_key_path.as_ref(),
            false,
        );
        if let Some(name) = &self.signing.gpg_private_key_env {
            signing.gpg_private_key = Some(read_secret_env(name)?);
        }
        if let Some(name) = &self.signing.gpg_private_key_passphrase_env {
            signing.gpg_private_key_passphrase = Some(read_secret_env(name)?);
        }
        Ok(())
    }
}

impl TaskBoardRuntimeIdentityArgs {
    fn has_update(&self) -> bool {
        self.author_name.is_some()
            || self.clear_author_name
            || self.author_email.is_some()
            || self.clear_author_email
            || self.ssh_key_path.is_some()
            || self.clear_ssh_key_path
            || self.ssh_private_key_env.is_some()
            || self.ssh_private_key_passphrase_env.is_some()
    }
}

impl TaskBoardRuntimeSigningArgs {
    fn has_update(&self) -> bool {
        self.signing_mode.is_some()
            || self.signing_ssh_key_path.is_some()
            || self.signing_ssh_private_key_env.is_some()
            || self.signing_ssh_private_key_passphrase_env.is_some()
            || self.gpg_key_id.is_some()
            || self.gpg_private_key_path.is_some()
            || self.gpg_private_key_env.is_some()
            || self.gpg_private_key_passphrase_env.is_some()
            || self.clear_signing
    }
}

impl From<TaskBoardGitSigningModeArg> for TaskBoardGitSigningMode {
    fn from(value: TaskBoardGitSigningModeArg) -> Self {
        match value {
            TaskBoardGitSigningModeArg::None => Self::None,
            TaskBoardGitSigningModeArg::Ssh => Self::Ssh,
            TaskBoardGitSigningModeArg::Gpg => Self::Gpg,
        }
    }
}

fn dry_run_override(dry_run: bool, apply: bool) -> Option<bool> {
    if dry_run {
        Some(true)
    } else if apply {
        Some(false)
    } else {
        None
    }
}

fn print_status(status: &TaskBoardOrchestratorStatus, json: bool) -> Result<i32, CliError> {
    if json {
        print_json(status)?;
    } else {
        println!(
            "task-board orchestrator: enabled={}, running={}, last_applied={}",
            status.enabled,
            status.running,
            status.last_run_applied_count()
        );
    }
    Ok(0)
}

fn repository_profile_mut<'a>(
    config: &'a mut TaskBoardGitRuntimeConfig,
    repository: &str,
) -> &'a mut TaskBoardGitRuntimeProfile {
    if let Some(index) = config
        .repository_overrides
        .iter()
        .position(|override_config| override_config.repository == repository)
    {
        return &mut config.repository_overrides[index].profile;
    }
    config
        .repository_overrides
        .push(TaskBoardGitRepositoryOverride {
            repository: repository.to_string(),
            profile: TaskBoardGitRuntimeProfile::default(),
        });
    &mut config
        .repository_overrides
        .last_mut()
        .expect("override")
        .profile
}

fn apply_optional_string(target: &mut Option<String>, value: Option<&String>, clear: bool) {
    if clear {
        *target = None;
    } else if let Some(value) = value {
        *target = Some(value.clone());
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

fn print_runtime_config_summary(config: &TaskBoardGitRuntimeConfig) {
    println!(
        "task-board runtime config: global_configured={}, repository_overrides={}",
        !config.global.is_empty(),
        config.repository_overrides.len()
    );
}
