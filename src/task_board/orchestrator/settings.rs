use std::collections::BTreeSet;
use std::path::Path;

use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};
#[cfg(test)]
use crate::task_board::normalize_repository_slug;
use crate::task_board::types::TaskBoardStatus;

use super::types::TaskBoardOrchestratorSettings;
#[cfg(test)]
use super::types::{
    TaskBoardGitHubInboxConfig, TaskBoardOrchestratorDispatchInput,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorSettingsUpdateRequest,
    TaskBoardTodoistInboxConfig,
};

/// Rewrite legacy persisted settings entries on disk so strict enum
/// deserializers can load older settings files. This repairs workflow names
/// written before the Dependencies → Reviews rename and legacy dispatch status
/// filters from earlier task-board lanes. Idempotent: once the file holds only
/// current variants, no write happens.
///
/// Returns the parsed settings when the file exists, or `None` when it is
/// absent. Callers can use the returned value directly to avoid a second
/// read of the same file.
///
/// # Errors
/// Returns `CliError` when the file is malformed JSON or cannot be rewritten.
#[cfg(test)]
pub(super) fn migrate_persisted_settings(
    path: &Path,
) -> Result<Option<TaskBoardOrchestratorSettings>, CliError> {
    load_normalized_settings(path, true)
}

/// Parse legacy settings with the same canonicalization as the live loader,
/// without rewriting the source. Used by the one-time database importer.
pub(crate) fn parse_persisted_settings_read_only(
    path: &Path,
) -> Result<Option<TaskBoardOrchestratorSettings>, CliError> {
    load_normalized_settings(path, false)
}

fn load_normalized_settings(
    path: &Path,
    persist_repairs: bool,
) -> Result<Option<TaskBoardOrchestratorSettings>, CliError> {
    if !path.exists() {
        return Ok(None);
    }
    let mut document: Value = read_json_typed(path)?;
    let workflows_changed = normalize_enabled_workflows(&mut document);
    let status_changed = repair_dispatch_status_filter(&mut document);
    if persist_repairs && (workflows_changed || status_changed) {
        write_json_pretty(path, &document)?;
    }
    let settings: TaskBoardOrchestratorSettings =
        serde_json::from_value(document).map_err(|error| {
            CliErrorKind::invalid_json(path.display().to_string()).with_details(error.to_string())
        })?;
    Ok(Some(settings))
}

fn normalize_enabled_workflows(document: &mut Value) -> bool {
    let Some(workflows) = document
        .as_object_mut()
        .and_then(|map| map.get_mut("enabled_workflows"))
        .and_then(Value::as_array_mut)
    else {
        return false;
    };
    let mut changed = false;
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut normalized: Vec<Value> = Vec::with_capacity(workflows.len());
    for entry in workflows.drain(..) {
        let Some(raw) = entry.as_str() else {
            normalized.push(entry);
            continue;
        };
        let canonical = if raw == "dependency_update" {
            changed = true;
            "review".to_owned()
        } else {
            raw.to_owned()
        };
        if seen.insert(canonical.clone()) {
            normalized.push(Value::String(canonical));
        } else {
            changed = true;
        }
    }
    *workflows = normalized;
    changed
}

fn repair_dispatch_status_filter(document: &mut Value) -> bool {
    let Some(status_value) = document
        .as_object()
        .and_then(|map| map.get("dispatch_status_filter"))
        .cloned()
    else {
        return false;
    };
    if status_value.as_str() == Some("umbrella") {
        document["dispatch_status_filter"] = Value::String("backlog".to_string());
        return true;
    }
    let Ok(status) = serde_json::from_value::<TaskBoardStatus>(status_value) else {
        return false;
    };
    let canonical = status.canonical_persisted_status();
    if status == canonical {
        return false;
    }
    let Ok(canonical_value) = serde_json::to_value(canonical) else {
        return false;
    };
    document["dispatch_status_filter"] = canonical_value;
    true
}

#[cfg(test)]
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
    if let Some(policy_version) = &update.policy_version {
        settings.policy_version.clone_from(policy_version);
    }
}

#[cfg(test)]
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

#[cfg(test)]
pub(super) fn normalize_todoist_inbox(
    inbox: &TaskBoardTodoistInboxConfig,
) -> TaskBoardTodoistInboxConfig {
    TaskBoardTodoistInboxConfig {
        project_filter: normalize_trimmed_unique(&inbox.project_filter),
    }
}

#[cfg(test)]
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

#[cfg(test)]
fn apply_status_filter_update(
    settings: &mut TaskBoardOrchestratorSettings,
    update: &TaskBoardOrchestratorSettingsUpdateRequest,
) {
    if update.clear_dispatch_status_filter {
        settings.dispatch_status_filter = None;
    } else if let Some(status) = update.dispatch_status_filter {
        settings.dispatch_status_filter = Some(status.canonical_persisted_status());
    }
}

#[cfg(test)]
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

#[cfg(test)]
pub(super) fn dispatch_input(
    request: &TaskBoardOrchestratorRunOnceRequest,
    settings: &TaskBoardOrchestratorSettings,
) -> TaskBoardOrchestratorDispatchInput {
    TaskBoardOrchestratorDispatchInput {
        item_id: request.item_id.clone(),
        status: canonical_status_filter(request.status.or(settings.dispatch_status_filter)),
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

#[cfg(test)]
fn canonical_status_filter(status: Option<TaskBoardStatus>) -> Option<TaskBoardStatus> {
    status.map(TaskBoardStatus::canonical_persisted_status)
}
