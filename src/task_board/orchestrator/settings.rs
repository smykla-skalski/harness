use std::collections::BTreeSet;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::normalize_repository_slug;

use super::types::{
    TaskBoardGitHubInboxConfig, TaskBoardOrchestratorDispatchInput,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorSettings,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardTodoistInboxConfig,
};

pub(super) fn apply_settings_update(
    settings: &mut TaskBoardOrchestratorSettings,
    update: &TaskBoardOrchestratorSettingsUpdateRequest,
) {
    if let Some(workflows) = &update.enabled_workflows {
        settings.enabled_workflows.clone_from(workflows);
    }
    if let Some(dry_run_default) = update.dry_run_default {
        settings.dry_run_default = dry_run_default;
    }
    apply_status_filter_update(settings, update);
    apply_project_update(settings, update);
    if let Some(github_project) = &update.github_project {
        settings.github_project.clone_from(github_project);
    }
    if let Some(github_inbox) = &update.github_inbox {
        settings.github_inbox.clone_from(github_inbox);
    }
    if let Some(todoist_inbox) = &update.todoist_inbox {
        settings.todoist_inbox.clone_from(todoist_inbox);
    }
    if let Some(policy_version) = &update.policy_version {
        settings.policy_version.clone_from(policy_version);
    }
}

pub(super) fn normalize_github_inbox(
    inbox: &TaskBoardGitHubInboxConfig,
) -> Result<TaskBoardGitHubInboxConfig, CliError> {
    let mut repositories = Vec::with_capacity(inbox.repositories.len());
    let mut seen = BTreeSet::new();
    for repository in &inbox.repositories {
        let Some(repository) = normalize_repository_slug(Some(repository.as_str())) else {
            return Err(CliError::from(CliErrorKind::workflow_parse(format!(
                "invalid task-board github inbox repository '{repository}', expected owner/repo"
            ))));
        };
        if seen.insert(repository.clone()) {
            repositories.push(repository);
        }
    }
    Ok(TaskBoardGitHubInboxConfig {
        repositories,
        label_filter: normalize_trimmed_unique(&inbox.label_filter),
    })
}

pub(super) fn normalize_todoist_inbox(
    inbox: &TaskBoardTodoistInboxConfig,
) -> TaskBoardTodoistInboxConfig {
    TaskBoardTodoistInboxConfig {
        project_filter: normalize_trimmed_unique(&inbox.project_filter),
    }
}

fn normalize_trimmed_unique(values: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::with_capacity(values.len());
    for value in values {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            continue;
        }
        if seen.insert(trimmed.to_owned()) {
            out.push(trimmed.to_owned());
        }
    }
    out
}

fn apply_status_filter_update(
    settings: &mut TaskBoardOrchestratorSettings,
    update: &TaskBoardOrchestratorSettingsUpdateRequest,
) {
    if update.clear_dispatch_status_filter {
        settings.dispatch_status_filter = None;
    } else if let Some(status) = update.dispatch_status_filter {
        settings.dispatch_status_filter = Some(status);
    }
}

fn apply_project_update(
    settings: &mut TaskBoardOrchestratorSettings,
    update: &TaskBoardOrchestratorSettingsUpdateRequest,
) {
    if update.clear_project_dir {
        settings.project_dir = None;
    } else if let Some(project_dir) = &update.project_dir {
        settings.project_dir = Some(project_dir.clone());
    }
}

pub(super) fn dispatch_input(
    request: &TaskBoardOrchestratorRunOnceRequest,
    settings: &TaskBoardOrchestratorSettings,
) -> TaskBoardOrchestratorDispatchInput {
    TaskBoardOrchestratorDispatchInput {
        item_id: request.item_id.clone(),
        status: request.status.or(settings.dispatch_status_filter),
        dry_run: request.dry_run.unwrap_or(settings.dry_run_default),
        project_dir: request
            .project_dir
            .clone()
            .or_else(|| settings.project_dir.clone())
            .or_else(|| {
                (!settings.github_project.checkout_path.as_os_str().is_empty()).then(|| {
                    settings
                        .github_project
                        .checkout_path
                        .to_string_lossy()
                        .into_owned()
                })
            }),
        actor: request.actor.clone(),
    }
}
