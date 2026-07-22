use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};

use crate::errors::CliError;
use crate::task_board::{
    TaskBoardExecutionHostConfig, TaskBoardLocalExecutionHostConfig,
    TaskBoardLocalExecutionRepositoryConfig, TaskBoardRepositoryAutomationConfig,
    normalize_repository_slug,
};

/// Validate controller trust anchors and repository routing as one config.
///
/// # Errors
/// Returns [`CliError`] for invalid/duplicate repositories or a preferred host
/// that is absent from the operator-owned trust-anchor set.
pub fn validate_remote_execution_configuration(
    hosts: &[TaskBoardExecutionHostConfig],
    repositories: &[TaskBoardRepositoryAutomationConfig],
) -> Result<(), CliError> {
    super::remote::validate_execution_host_configs(hosts)?;
    let host_ids: BTreeSet<&str> = hosts.iter().map(|host| host.host_id.as_str()).collect();
    let mut repository_ids = BTreeSet::new();
    for repository in repositories {
        validate_repository_remote_execution_config(repository)?;
        if !repository_ids.insert(repository.repository.as_str()) {
            return Err(parse_error(format!(
                "duplicate remote execution repository '{}'",
                repository.repository
            )));
        }
        if let Some(preferred) = repository.preferred_host_id.as_deref()
            && !host_ids.contains(preferred)
        {
            return Err(parse_error(format!(
                "preferred remote execution host '{preferred}' is not configured"
            )));
        }
    }
    Ok(())
}

use super::remote::{
    parse_error, validate_canonical_id, validate_capability_inventory, validate_runtime_inventory,
};

/// Validate repository-scoped remote execution settings.
///
/// # Errors
/// Returns [`CliError`] for a noncanonical repository/host identity or an
/// unsafe checkout source path.
pub fn validate_repository_remote_execution_config(
    repository: &TaskBoardRepositoryAutomationConfig,
) -> Result<(), CliError> {
    if normalize_repository_slug(Some(&repository.repository)).as_deref()
        != Some(repository.repository.as_str())
    {
        return Err(parse_error(format!(
            "remote execution repository '{}' is not canonical",
            repository.repository
        )));
    }
    if let Some(host_id) = repository.preferred_host_id.as_deref() {
        validate_canonical_id(host_id, "preferred remote execution host id")?;
    }
    if let Some(checkout_path) = repository.execution_checkout_path.as_deref() {
        validate_checkout_path(checkout_path)?;
    }
    Ok(())
}

/// Validate one daemon's operator-owned, default-off executor identity.
///
/// The all-empty disabled default is valid. Once any host field is configured,
/// identity, capacity, repository roots, runtimes, and remote-only
/// capabilities must form a complete deterministic configuration.
///
/// # Errors
/// Returns [`CliError`] for partial, unsafe, noncanonical, or duplicate fields.
pub fn validate_local_execution_host_config(
    host: &TaskBoardLocalExecutionHostConfig,
) -> Result<(), CliError> {
    if is_empty_disabled_host(host) {
        return Ok(());
    }
    validate_canonical_id(&host.host_id, "local execution host id")?;
    if host.capacity == 0 {
        return Err(parse_error(
            "local execution host capacity must be positive",
        ));
    }
    if host.repositories.is_empty() || host.runtimes.is_empty() || host.capabilities.is_empty() {
        return Err(parse_error(
            "local execution host repositories, runtimes, and capabilities must be configured",
        ));
    }
    validate_local_repositories(&host.repositories)?;
    validate_runtime_inventory(&host.runtimes)?;
    validate_capability_inventory(&host.capabilities)
}

fn validate_local_repositories(
    repositories: &[TaskBoardLocalExecutionRepositoryConfig],
) -> Result<(), CliError> {
    let mut previous = None;
    for repository in repositories {
        if normalize_repository_slug(Some(&repository.repository)).as_deref()
            != Some(repository.repository.as_str())
        {
            return Err(parse_error(format!(
                "local execution repository '{}' is not canonical",
                repository.repository
            )));
        }
        if previous.is_some_and(|previous| previous >= repository.repository.as_str()) {
            return Err(parse_error(
                "local execution repositories must be sorted and unique",
            ));
        }
        validate_checkout_path(&repository.checkout_path)?;
        previous = Some(repository.repository.as_str());
    }
    Ok(())
}

fn validate_checkout_path(value: &str) -> Result<(), CliError> {
    let path = Path::new(value);
    let canonical: PathBuf = path.components().collect();
    let safe = !value.is_empty()
        && value.trim() == value
        && path.is_absolute()
        && path != Path::new("/")
        && canonical_checkout_segments(value)
        && canonical == path
        && !path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
        && !value.chars().any(char::is_control);
    if safe {
        Ok(())
    } else {
        Err(parse_error(format!(
            "remote execution checkout path '{value}' must be canonical and absolute"
        )))
    }
}

fn canonical_checkout_segments(value: &str) -> bool {
    value.strip_prefix('/').is_some_and(|relative| {
        !relative.is_empty()
            && relative
                .split('/')
                .all(|segment| !segment.is_empty() && !matches!(segment, "." | ".."))
    })
}

fn is_empty_disabled_host(host: &TaskBoardLocalExecutionHostConfig) -> bool {
    !host.enabled
        && host.host_id.is_empty()
        && host.capacity == 0
        && host.repositories.is_empty()
        && host.runtimes.is_empty()
        && host.capabilities.is_empty()
}
