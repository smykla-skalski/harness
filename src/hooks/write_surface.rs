use std::path::{Component, Path, PathBuf};

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
