use std::collections::BTreeSet;

use crate::daemon::protocol::TaskBoardOrchestratorSettingsUpdateRequest;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TaskBoardGitHubInboxConfig, TaskBoardOrchestratorSettings, TaskBoardTodoistInboxConfig,
    normalize_repository_slug,
};

pub(super) fn apply_settings_update(
    settings: &mut TaskBoardOrchestratorSettings,
    update: &TaskBoardOrchestratorSettingsUpdateRequest,
) {
    if let Some(step_mode) = update.step_mode {
        settings.step_mode = step_mode;
    }
    if let Some(workflows) = &update.enabled_workflows {
        settings.enabled_workflows.clone_from(workflows);
    }
    if let Some(dry_run_default) = update.dry_run_default {
        settings.dry_run_default = dry_run_default;
    }
    apply_optional_fields(settings, update);
    apply_automation_fields(settings, update);
}

fn apply_optional_fields(
    settings: &mut TaskBoardOrchestratorSettings,
    update: &TaskBoardOrchestratorSettingsUpdateRequest,
) {
    if update.clear_dispatch_status_filter {
        settings.dispatch_status_filter = None;
    } else if let Some(status) = update.dispatch_status_filter {
        settings.dispatch_status_filter = Some(status.canonical_persisted_status());
    }
    if update.clear_project_dir {
        settings.project_dir = None;
    } else if let Some(project_dir) = &update.project_dir {
        settings.project_dir = Some(project_dir.clone());
    }
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

fn apply_automation_fields(
    settings: &mut TaskBoardOrchestratorSettings,
    update: &TaskBoardOrchestratorSettingsUpdateRequest,
) {
    if let Some(scheduling) = &update.scheduling {
        settings.scheduling.clone_from(scheduling);
    }
    if let Some(retry) = &update.retry {
        settings.retry.clone_from(retry);
    }
    if let Some(reviewers) = &update.reviewers {
        settings.reviewers.clone_from(reviewers);
    }
    if let Some(repositories) = &update.repositories {
        settings.repositories.clone_from(repositories);
    }
    if let Some(execution_hosts) = &update.execution_hosts {
        settings.execution_hosts.clone_from(execution_hosts);
    }
    if let Some(admission_policy) = &update.admission_policy {
        settings.admission_policy.clone_from(admission_policy);
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
        label_filter: normalize_strings(&inbox.label_filter),
    })
}

pub(super) fn normalize_todoist_inbox(
    inbox: &TaskBoardTodoistInboxConfig,
) -> TaskBoardTodoistInboxConfig {
    TaskBoardTodoistInboxConfig {
        project_filter: normalize_strings(&inbox.project_filter),
    }
}

fn normalize_strings(values: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    values
        .iter()
        .filter_map(|value| {
            let value = value.trim();
            (!value.is_empty() && seen.insert(value.to_owned())).then(|| value.to_owned())
        })
        .collect()
}
