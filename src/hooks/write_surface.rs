use std::path::{Component, Path, PathBuf};

use crate::kernel::run_surface::RunFile;

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
    let normalized_path = normalize_path(path);
    RunFile::ALL
        .iter()
        .filter(|file| file.is_direct_write_denied())
        .any(|file| normalized_path == normalize_path(&run_dir.join(file.to_string())))
}

/// Provides a user-facing hint for a denied control-file write.
pub(crate) fn control_file_hint(path: &Path) -> &'static str {
    let name = path
        .file_name()
        .map_or("", |name| name.to_str().unwrap_or(""));
    if name == "command-log.md" {
        RunFile::COMMAND_LOG_HINT
    } else {
        RunFile::CONTROL_HINT
    }
}
