use std::env;
use std::fs;
use std::path::PathBuf;

use crate::errors::{CliError, CliErrorKind};

/// Locate a session JSONL file under `~/.claude/projects/*/`.
///
/// Walks all project directories and returns the path to `{session_id}.jsonl`.
/// If `project_hint` is set, narrows the search to directories whose name
/// contains the hint.
///
/// # Errors
/// Returns `SessionNotFound` when the session file cannot be located.
pub fn find_session(session_id: &str, project_hint: Option<&str>) -> Result<PathBuf, CliError> {
    let home =
        env::var("HOME").map_err(|_| CliErrorKind::session_not_found(session_id.to_string()))?;
    let claude_dir = PathBuf::from(home).join(".claude").join("projects");

    if !claude_dir.is_dir() {
        return Err(CliErrorKind::session_not_found(session_id.to_string()).into());
    }

    let mut candidates = Vec::new();

    let entries = fs::read_dir(&claude_dir)
        .map_err(|_| CliErrorKind::session_not_found(session_id.to_string()))?;

    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        if let Some(hint) = project_hint {
            let dir_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if !dir_name.contains(hint) {
                continue;
            }
        }
        let candidate = path.join(format!("{session_id}.jsonl"));
        if candidate.exists() {
            candidates.push(candidate);
        }
    }

    if candidates.is_empty() {
        return Err(CliErrorKind::session_not_found(session_id.to_string()).into());
    }

    if candidates.len() == 1 {
        return Ok(candidates.swap_remove(0));
    }

    // Multiple matches - just return the first one. The project_hint filter
    // was already applied when building the candidate list (lines 34-38).
    Ok(candidates.swap_remove(0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_session_in_temp_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let project_dir = tmp
            .path()
            .join(".claude")
            .join("projects")
            .join("test-project");
        fs::create_dir_all(&project_dir).unwrap();
        let session_file = project_dir.join("abc123.jsonl");
        fs::write(&session_file, "{}\n").unwrap();

        temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
            let result = find_session("abc123", None);
            assert!(result.is_ok());
            assert_eq!(result.unwrap(), session_file);
        });
    }

    #[test]
    fn find_session_with_hint() {
        let tmp = tempfile::tempdir().unwrap();
        let project_a = tmp.path().join(".claude").join("projects").join("alpha");
        let project_b = tmp.path().join(".claude").join("projects").join("beta");
        fs::create_dir_all(&project_a).unwrap();
        fs::create_dir_all(&project_b).unwrap();
        fs::write(project_a.join("sess.jsonl"), "{}\n").unwrap();
        fs::write(project_b.join("sess.jsonl"), "{}\n").unwrap();

        temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
            let result = find_session("sess", Some("beta"));
            assert!(result.is_ok());
            let path = result.unwrap();
            assert!(path.to_string_lossy().contains("beta"));
        });
    }

    #[test]
    fn find_session_not_found() {
        let tmp = tempfile::tempdir().unwrap();
        let project_dir = tmp.path().join(".claude").join("projects").join("proj");
        fs::create_dir_all(&project_dir).unwrap();

        temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
            let result = find_session("nonexistent", None);
            assert!(result.is_err());
            let err = result.unwrap_err();
            assert_eq!(err.code(), "KSRCLI080");
        });
    }

    #[test]
    fn find_session_no_claude_dir() {
        let tmp = tempfile::tempdir().unwrap();
        temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
            let result = find_session("whatever", None);
            assert!(result.is_err());
        });
    }
}
