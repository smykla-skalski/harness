use std::path::{Component, Path, PathBuf};

use crate::rules::suite_runner as runner_rules;

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
    runner_rules::DIRECT_WRITE_DENIED_RUN_FILES
        .iter()
        .any(|rel| norm == normalize_path(&run_dir.join(rel)))
}

/// Provides a user-facing hint for a denied control-file write.
pub(crate) fn control_file_hint(path: &Path) -> &'static str {
    let name = path.file_name().map_or("", |n| n.to_str().unwrap_or(""));
    if name == "command-log.md" {
        runner_rules::COMMAND_LOG_HINT
    } else {
        runner_rules::HARNESS_MANAGED_RUN_CONTROL_HINT
    }
}
