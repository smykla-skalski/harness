use std::path::PathBuf;

use walkdir::WalkDir;

use crate::workspace::dirs_home;
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
mod tests {
    use std::fs;

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

    #[test]
    fn find_session_ambiguous_without_hint() {
        let tmp = tempfile::tempdir().unwrap();
        let project_a = tmp.path().join(".claude").join("projects").join("alpha");
        let project_b = tmp.path().join(".claude").join("projects").join("beta");
        fs::create_dir_all(&project_a).unwrap();
        fs::create_dir_all(&project_b).unwrap();
        fs::write(project_a.join("shared.jsonl"), "{}\n").unwrap();
        fs::write(project_b.join("shared.jsonl"), "{}\n").unwrap();

        temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
            let result = find_session("shared", None);
            assert!(result.is_err());
            let err = result.unwrap_err();
            assert_eq!(err.code(), "KSRCLI085");
        });
    }
}
