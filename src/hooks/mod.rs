use std::path::{Component, Path, PathBuf};

use crate::rules::suite_runner::RunFile;

pub mod audit;
pub mod context_agent;
pub mod enrich_failure;
pub mod guard_bash;
pub mod guard_question;
pub mod guard_stop;
pub mod guard_write;
pub mod validate_agent;
pub mod verify_bash;
pub mod verify_question;
pub mod verify_write;

/// Normalize a path by resolving `.` and `..` segments without touching the
/// filesystem. Unlike `std::fs::canonicalize`, this works on paths that do not
/// exist yet.
pub(crate) fn normalize_path(path: &Path) -> PathBuf {
    let mut parts: Vec<Component<'_>> = Vec::new();
    for comp in path.components() {
        match comp {
            Component::CurDir => {}
            Component::ParentDir => {
                if let Some(Component::Normal(_)) = parts.last() {
                    parts.pop();
                } else {
                    parts.push(comp);
                }
            }
            _ => parts.push(comp),
        }
    }
    parts.iter().collect()
}

/// Returns `true` when `path` refers to a harness-managed run control file
/// inside `run_dir`.
pub(crate) fn is_command_owned_run_file(path: &Path, run_dir: &Path) -> bool {
    let norm = normalize_path(path);
    RunFile::ALL
        .iter()
        .filter(|f| f.is_direct_write_denied())
        .any(|f| norm == normalize_path(&run_dir.join(f.to_string())))
}

/// Provides a user-facing hint for a denied control-file write.
pub(crate) fn control_file_hint(path: &Path) -> &'static str {
    let name = path.file_name().map_or("", |n| n.to_str().unwrap_or(""));
    if name == "command-log.md" {
        RunFile::COMMAND_LOG_HINT
    } else {
        RunFile::CONTROL_HINT
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_path_resolves_dot_dot() {
        let path = Path::new("/a/b/../c");
        assert_eq!(normalize_path(path), PathBuf::from("/a/c"));
    }

    #[test]
    fn normalize_path_resolves_dot() {
        let path = Path::new("/a/./b/./c");
        assert_eq!(normalize_path(path), PathBuf::from("/a/b/c"));
    }

    #[test]
    fn normalize_path_preserves_absolute() {
        let path = Path::new("/a/b/c");
        assert_eq!(normalize_path(path), PathBuf::from("/a/b/c"));
    }

    #[test]
    fn is_command_owned_run_report() {
        assert!(is_command_owned_run_file(
            Path::new("/runs/run-1/run-report.md"),
            Path::new("/runs/run-1")
        ));
    }

    #[test]
    fn is_command_owned_run_status() {
        assert!(is_command_owned_run_file(
            Path::new("/runs/run-1/run-status.json"),
            Path::new("/runs/run-1")
        ));
    }

    #[test]
    fn is_command_owned_runner_state() {
        assert!(is_command_owned_run_file(
            Path::new("/runs/run-1/suite-run-state.json"),
            Path::new("/runs/run-1")
        ));
    }

    #[test]
    fn is_command_owned_command_log() {
        assert!(is_command_owned_run_file(
            Path::new("/runs/run-1/commands/command-log.md"),
            Path::new("/runs/run-1")
        ));
    }

    #[test]
    fn is_not_command_owned_artifact() {
        assert!(!is_command_owned_run_file(
            Path::new("/runs/run-1/artifacts/state.json"),
            Path::new("/runs/run-1")
        ));
    }

    #[test]
    fn is_not_command_owned_different_run() {
        assert!(!is_command_owned_run_file(
            Path::new("/runs/run-2/run-report.md"),
            Path::new("/runs/run-1")
        ));
    }

    #[test]
    fn control_file_hint_command_log() {
        let hint = control_file_hint(Path::new("commands/command-log.md"));
        assert!(hint.contains("harness record"));
    }

    #[test]
    fn control_file_hint_other() {
        let hint = control_file_hint(Path::new("run-report.md"));
        assert!(hint.contains("harness report group"));
    }
}
