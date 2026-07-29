#[cfg(any(test, feature = "test-support", feature = "daemon-runtime"))]
use std::collections::BTreeSet;
#[cfg(any(test, feature = "test-support", feature = "daemon-runtime"))]
use std::path::Path;

#[cfg(any(test, feature = "test-support", feature = "daemon-runtime"))]
use serde_json::Value;

#[cfg(any(test, feature = "test-support", feature = "daemon-runtime"))]
use harness_infra::io::{read_json_typed, write_json_pretty};
#[cfg(any(test, feature = "test-support", feature = "daemon-runtime"))]
use harness_kernel::errors::{CliError, CliErrorKind};

#[cfg(any(test, feature = "test-support"))]
use crate::normalize_repository_slug;
#[cfg(any(test, feature = "test-support", feature = "daemon-runtime"))]
use crate::types::TaskBoardStatus;

#[cfg(any(test, feature = "test-support", feature = "daemon-runtime"))]
use super::types::TaskBoardOrchestratorSettings;
#[cfg(any(test, feature = "test-support"))]
use super::types::{
    TaskBoardGitHubInboxConfig, TaskBoardOrchestratorDispatchInput,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorSettingsUpdateRequest,
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
#[cfg(any(test, feature = "test-support"))]
pub(super) fn migrate_persisted_settings(
    path: &Path,
) -> Result<Option<TaskBoardOrchestratorSettings>, CliError> {
    load_normalized_settings(path, true)
}

/// Parse legacy settings with the same canonicalization as the live loader,
/// without rewriting the source. Used by the one-time database importer.
#[cfg(feature = "daemon-runtime")]
pub(crate) fn parse_persisted_settings_read_only(
    path: &Path,
) -> Result<Option<TaskBoardOrchestratorSettings>, CliError> {
    load_normalized_settings(path, false)
}

#[cfg(any(test, feature = "test-support", feature = "daemon-runtime"))]
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

#[cfg(any(test, feature = "test-support", feature = "daemon-runtime"))]
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

#[cfg(any(test, feature = "test-support", feature = "daemon-runtime"))]
fn repair_dispatch_status_filter(document: &mut Value) -> bool {
    let Some(status_value) = document
        .as_object()
        .and_then(|map| map.get("dispatch_status_filter"))
        .cloned()
    else {
        return false;
    };
    if matches!(status_value.as_str(), Some("umbrella" | "backlog")) {
        document["dispatch_status_filter"] = Value::String("inbox".to_string());
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

#[cfg(any(test, feature = "test-support"))]
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
    apply_automation_update(settings, update);
}

// Split from `apply_settings_update` alongside `apply_status_filter_update`/
// `apply_project_update`, and further split between the two functions below:
// the automation-facing fields (GitHub project/inbox, scheduling, retry,
// reviewers, repositories, execution hosts, admission policy, policy
// version) are the bulk of the update and pushed clippy's
// cognitive-complexity threshold past 7 once test-support widened this test
// double to run under a plain library build too.
#[cfg(any(test, feature = "test-support"))]
fn apply_automation_update(
    settings: &mut TaskBoardOrchestratorSettings,
    update: &TaskBoardOrchestratorSettingsUpdateRequest,
) {
    if let Some(github_project) = &update.github_project {
        settings.github_project.clone_from(github_project);
    }
    if let Some(github_inbox) = &update.github_inbox {
        settings.github_inbox.clone_from(github_inbox);
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
    apply_execution_update(settings, update);
}

#[cfg(any(test, feature = "test-support"))]
fn apply_execution_update(
    settings: &mut TaskBoardOrchestratorSettings,
    update: &TaskBoardOrchestratorSettingsUpdateRequest,
) {
    if let Some(repositories) = &update.repositories {
        settings.repositories.clone_from(repositories);
    }
    if let Some(execution_hosts) = &update.execution_hosts {
        settings.execution_hosts.clone_from(execution_hosts);
    }
    if let Some(local_execution_host) = &update.local_execution_host {
        settings
            .local_execution_host
            .clone_from(local_execution_host);
    }
    if let Some(admission_policy) = &update.admission_policy {
        settings.admission_policy.clone_from(admission_policy);
    }
    if let Some(policy_version) = &update.policy_version {
        settings.policy_version.clone_from(policy_version);
    }
}

#[cfg(any(test, feature = "test-support"))]
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

#[cfg(any(test, feature = "test-support"))]
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

#[cfg(any(test, feature = "test-support"))]
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

#[cfg(any(test, feature = "test-support"))]
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

#[cfg(any(test, feature = "test-support"))]
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
            .or_else(|| settings.project_dir.clone()),
        actor: request.actor.clone(),
    }
}

#[cfg(any(test, feature = "test-support"))]
fn canonical_status_filter(status: Option<TaskBoardStatus>) -> Option<TaskBoardStatus> {
    status.map(TaskBoardStatus::canonical_persisted_status)
}
