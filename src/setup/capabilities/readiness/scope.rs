use std::path::{Path, PathBuf};

use crate::setup::capabilities::model::ReadinessScope;

pub(super) fn build_scope(
    cwd: &Path,
    project_dir: &Path,
    explicit_project_dir: bool,
) -> ReadinessScope {
    ReadinessScope {
        cwd: cwd.display().to_string(),
        project_dir: project_dir.display().to_string(),
        explicit_project_dir,
    }
}

pub(super) fn resolve_scope_path(raw: Option<&str>, cwd: &Path) -> PathBuf {
    raw.map_or_else(
        || cwd.to_path_buf(),
        |value| {
            let path = PathBuf::from(value);
            if path.is_absolute() {
                path
            } else {
                cwd.join(path)
            }
        },
    )
}
