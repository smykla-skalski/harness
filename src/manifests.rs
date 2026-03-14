use std::path::{Path, PathBuf};

/// Resolve a manifest path, joining with run_dir if relative.
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
    manifest.with_extension("validation.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_manifest_path_absolute_returned_as_is() {
        let result = resolve_manifest_path("/absolute/path.yaml", None);
        assert_eq!(result, PathBuf::from("/absolute/path.yaml"));
    }

    #[test]
    fn resolve_manifest_path_relative_with_run_dir() {
        let run_dir = Path::new("/runs/run-001");
        let result = resolve_manifest_path("g01.yaml", Some(run_dir));
        assert_eq!(result, PathBuf::from("/runs/run-001/g01.yaml"));
    }

    #[test]
    fn resolve_manifest_path_relative_without_run_dir() {
        let result = resolve_manifest_path("g01.yaml", None);
        assert_eq!(result, PathBuf::from("g01.yaml"));
    }

    #[test]
    fn default_validation_output_changes_extension() {
        let manifest = Path::new("/runs/manifests/g01.yaml");
        let result = default_validation_output(manifest);
        assert_eq!(result, PathBuf::from("/runs/manifests/g01.validation.json"));
    }

    #[test]
    fn default_validation_output_no_extension() {
        let manifest = Path::new("/runs/manifests/g01");
        let result = default_validation_output(manifest);
        assert_eq!(result, PathBuf::from("/runs/manifests/g01.validation.json"));
    }

    #[test]
    fn resolve_manifest_path_absolute_with_run_dir_ignores_run_dir() {
        let run_dir = Path::new("/runs/run-001");
        let result = resolve_manifest_path("/absolute/path.yaml", Some(run_dir));
        assert_eq!(result, PathBuf::from("/absolute/path.yaml"));
    }

    #[test]
    fn resolve_manifest_path_nested_relative() {
        let run_dir = Path::new("/runs/run-001");
        let result = resolve_manifest_path("sub/dir/g01.yaml", Some(run_dir));
        assert_eq!(result, PathBuf::from("/runs/run-001/sub/dir/g01.yaml"));
    }
}
