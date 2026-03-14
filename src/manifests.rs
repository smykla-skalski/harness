use std::path::{Path, PathBuf};

/// Resolve a manifest path, joining with `run_dir` if relative.
#[must_use]
pub fn resolve_manifest_path(raw: &str, run_dir: Option<&Path>) -> PathBuf {
    let path = PathBuf::from(raw);
    if path.is_absolute() {
        return path;
    }
    if let Some(rd) = run_dir {
        return rd.join(&path);
    }
    path
}

/// Default validation output path for a manifest.
#[must_use]
pub fn default_validation_output(manifest: &Path) -> PathBuf {
    manifest.with_extension("validate.txt")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_absolute_path_unchanged() {
        let result = resolve_manifest_path("/abs/manifest.yaml", Some(Path::new("/run")));
        assert_eq!(result, PathBuf::from("/abs/manifest.yaml"));
    }

    #[test]
    fn resolve_relative_with_run_dir() {
        let result = resolve_manifest_path("manifests/foo.yaml", Some(Path::new("/run/dir")));
        assert_eq!(result, PathBuf::from("/run/dir/manifests/foo.yaml"));
    }

    #[test]
    fn resolve_relative_without_run_dir() {
        let result = resolve_manifest_path("manifests/foo.yaml", None);
        assert_eq!(result, PathBuf::from("manifests/foo.yaml"));
    }

    #[test]
    fn default_validation_output_extension() {
        let result = default_validation_output(Path::new("/run/manifests/foo.yaml"));
        assert_eq!(result, PathBuf::from("/run/manifests/foo.validate.txt"));
    }
}
