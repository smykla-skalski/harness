use std::path::PathBuf;

use walkdir::WalkDir;

use crate::agents::storage::find_canonical_session;
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::dirs_home;

/// Locate a session JSONL file, preferring the canonical harness agent ledger.
///
/// The shared harness ledger is the source of truth for cross-agent sessions.
/// Legacy Claude transcript lookup remains as a compatibility fallback while
/// older sessions are still present on disk.
///
/// # Errors
/// Returns `SessionNotFound` when the session file cannot be located.
pub fn find_session(session_id: &str, project_hint: Option<&str>) -> Result<PathBuf, CliError> {
    if let Some(path) = find_canonical_session(session_id, project_hint)? {
        return Ok(path);
    }

    let claude_dir = dirs_home().join(".claude").join("projects");

    if !claude_dir.is_dir() {
        return Err(CliErrorKind::session_not_found(session_id.to_string()).into());
    }

    let mut candidates = Vec::new();
    let session_file_name = format!("{session_id}.jsonl");

    for entry in WalkDir::new(&claude_dir)
        .min_depth(2)
        .max_depth(2)
        .sort_by_file_name()
    {
        let Ok(entry) = entry else {
            continue;
        };
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        if path.file_name().and_then(|name| name.to_str()) != Some(session_file_name.as_str()) {
            continue;
        }
        let Some(project_dir) = path.parent() else {
            continue;
        };
        if let Some(hint) = project_hint {
            let dir_name = project_dir
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("");
            if !dir_name.contains(hint) {
                continue;
            }
        }
        candidates.push(path.to_path_buf());
    }

    if candidates.is_empty() {
        return Err(CliErrorKind::session_not_found(session_id.to_string()).into());
    }

    if candidates.len() == 1 {
        return Ok(candidates.swap_remove(0));
    }

    // Multiple matches without a hint -> ambiguous
    let project_names: Vec<String> = candidates
        .iter()
        .filter_map(|p| {
            p.parent()
                .and_then(|d| d.file_name())
                .and_then(|n| n.to_str())
                .map(String::from)
        })
        .collect();
    Err(CliErrorKind::session_ambiguous(format!(
        "session '{session_id}' found in {} projects: {}",
        candidates.len(),
        project_names.join(", ")
    ))
    .into())
}

#[cfg(test)]
mod tests;
