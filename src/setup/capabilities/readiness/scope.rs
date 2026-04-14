use std::path::{Path, PathBuf};

use fs_err as fs;

use crate::setup::capabilities::model::ReadinessScope;

pub(super) fn build_scope(
    cwd: &Path,
    project_dir: &Path,
    repo_root: Option<&Path>,
    explicit_project_dir: bool,
    explicit_repo_root: bool,
) -> ReadinessScope {
    ReadinessScope {
        cwd: cwd.display().to_string(),
        project_dir: project_dir.display().to_string(),
        repo_root: repo_root.map(|path| path.display().to_string()),
        explicit_project_dir,
        explicit_repo_root,
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

pub(super) fn auto_detect_kuma_repo_root(start: &Path) -> Option<PathBuf> {
    start.ancestors().find_map(|ancestor| {
        let go_mod = ancestor.join("go.mod");
        let text = fs::read_to_string(&go_mod).ok()?;
        if text.contains("github.com/kumahq/kuma") {
            Some(ancestor.to_path_buf())
        } else {
            None
        }
    })
}
