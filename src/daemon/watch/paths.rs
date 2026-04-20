use std::path::{Component, Path, PathBuf};

use crate::daemon::index;
use crate::errors::CliError;

use super::state::{RuntimeSessionResolveCache, RuntimeSessionTarget};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum WatchPathTarget {
    Session(String),
    Transcript {
        session_id: String,
        runtime_name: String,
        runtime_session_id: String,
    },
}

#[cfg(test)]
pub(super) fn watch_target_from_path(path: &Path) -> Result<Option<WatchPathTarget>, CliError> {
    let mut resolve_cache = RuntimeSessionResolveCache::default();
    watch_target_from_path_with_cache(path, &mut resolve_cache)
}

#[cfg(test)]
pub(super) fn session_id_from_path(path: &Path) -> Result<Option<String>, CliError> {
    let mut resolve_cache = RuntimeSessionResolveCache::default();
    session_id_from_path_with_cache(path, &mut resolve_cache)
}

pub(super) fn session_id_from_path_with_cache(
    path: &Path,
    resolve_cache: &mut RuntimeSessionResolveCache,
) -> Result<Option<String>, CliError> {
    Ok(
        watch_target_from_path_with_cache(path, resolve_cache)?.map(|target| match target {
            WatchPathTarget::Session(session_id)
            | WatchPathTarget::Transcript { session_id, .. } => session_id,
        }),
    )
}

pub(super) fn watch_target_from_path_with_cache(
    path: &Path,
    resolve_cache: &mut RuntimeSessionResolveCache,
) -> Result<Option<WatchPathTarget>, CliError> {
    watch_target_from_path_with(
        path,
        resolve_cache,
        &mut |context_root, runtime_name, runtime_session_id| {
            let project = index::discovered_project_for_context_root(context_root);
            index::resolve_session_id_for_runtime_session(
                &project,
                runtime_name,
                runtime_session_id,
            )
        },
    )
}

pub(super) fn watch_target_from_path_with<F>(
    path: &Path,
    resolve_cache: &mut RuntimeSessionResolveCache,
    resolver: &mut F,
) -> Result<Option<WatchPathTarget>, CliError>
where
    F: FnMut(&Path, &str, &str) -> Result<Option<String>, CliError>,
{
    if let Some(session_id) = orchestration_session_id_from_path(path) {
        return Ok(Some(WatchPathTarget::Session(session_id)));
    }
    if let Some(target) = runtime_session_target_from_transcript(path) {
        let runtime_name = target.runtime_name.clone();
        let runtime_session_id = target.runtime_session_id.clone();
        return Ok(resolve_cache
            .resolve_with(target, resolver)?
            .map(|session_id| WatchPathTarget::Transcript {
                session_id,
                runtime_name,
                runtime_session_id,
            }));
    }
    if let Some(target) = runtime_session_target_from_signal(path) {
        return Ok(resolve_cache
            .resolve_with(target, resolver)?
            .map(WatchPathTarget::Session));
    }
    Ok(None)
}

#[cfg(test)]
pub(super) fn session_id_from_path_with<F>(
    path: &Path,
    resolve_cache: &mut RuntimeSessionResolveCache,
    resolver: &mut F,
) -> Result<Option<String>, CliError>
where
    F: FnMut(&Path, &str, &str) -> Result<Option<String>, CliError>,
{
    Ok(
        watch_target_from_path_with(path, resolve_cache, resolver)?.map(|target| match target {
            WatchPathTarget::Session(session_id)
            | WatchPathTarget::Transcript { session_id, .. } => session_id,
        }),
    )
}

fn orchestration_session_id_from_path(path: &Path) -> Option<String> {
    let components: Vec<_> = path
        .components()
        .filter_map(|component| match component {
            Component::Normal(part) => Some(part.to_string_lossy().to_string()),
            _ => None,
        })
        .collect();
    components.windows(3).find_map(|window| match window {
        [first, second, session_id] if first == "orchestration" && second == "sessions" => {
            Some(session_id.clone())
        }
        _ => None,
    })
}

pub(super) fn orchestration_context_root(path: &Path) -> Option<PathBuf> {
    path.ancestors().find_map(|ancestor| {
        (ancestor.file_name().and_then(|name| name.to_str()) == Some("orchestration"))
            .then(|| ancestor.parent().map(Path::to_path_buf))
            .flatten()
    })
}

fn runtime_session_target_from_transcript(path: &Path) -> Option<RuntimeSessionTarget> {
    if path.file_name().and_then(|name| name.to_str()) != Some("raw.jsonl") {
        return None;
    }
    let runtime_session_id = ancestor_name(path, 1)?;
    let runtime_name = ancestor_name(path, 2)?;
    if !has_ancestor_names(path, 3, "sessions", "agents") {
        return None;
    }
    Some(RuntimeSessionTarget {
        context_root: path.ancestors().nth(5)?.to_path_buf(),
        runtime_name,
        runtime_session_id,
    })
}

fn runtime_session_target_from_signal(path: &Path) -> Option<RuntimeSessionTarget> {
    if !is_signal_bucket_path(path) {
        return None;
    }
    let runtime_session_id = ancestor_name(path, 2)?;
    let runtime_name = ancestor_name(path, 3)?;
    if !has_ancestor_names(path, 4, "signals", "agents") {
        return None;
    }
    Some(RuntimeSessionTarget {
        context_root: path.ancestors().nth(6)?.to_path_buf(),
        runtime_name,
        runtime_session_id,
    })
}

fn is_signal_bucket_path(path: &Path) -> bool {
    path.parent()
        .and_then(|parent| parent.file_name())
        .and_then(|name| name.to_str())
        .is_some_and(|bucket| matches!(bucket, "pending" | "acknowledged"))
}

fn ancestor_name(path: &Path, depth: usize) -> Option<String> {
    path.ancestors()
        .nth(depth)
        .and_then(|ancestor| ancestor.file_name())
        .map(|name| name.to_string_lossy().to_string())
}

/// Check whether `path.ancestors().nth(depth)` has the given file name and
/// `path.ancestors().nth(depth + 1)` has `outer_name`.
fn has_ancestor_names(path: &Path, depth: usize, inner_name: &str, outer_name: &str) -> bool {
    let inner_match = path
        .ancestors()
        .nth(depth)
        .and_then(|ancestor| ancestor.file_name())
        .and_then(|name| name.to_str())
        == Some(inner_name);
    let outer_match = path
        .ancestors()
        .nth(depth + 1)
        .and_then(|ancestor| ancestor.file_name())
        .and_then(|name| name.to_str())
        == Some(outer_name);
    inner_match && outer_match
}
