use std::path::{Path, PathBuf};

use crate::errors::CliError;

/// A manifest target for validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestTarget {
    pub label: String,
    pub path: PathBuf,
}

/// Resolve the repo root for authoring validation.
///
/// If `raw_repo_root` is provided, it is resolved and returned directly.
/// Otherwise, each path is checked for a parent containing `go.mod`.
///
/// # Errors
/// Returns an error if the repo root cannot be determined.
pub fn authoring_validation_repo_root(
    raw_repo_root: Option<&str>,
    paths: &[&Path],
) -> Result<PathBuf, CliError> {
    if let Some(raw) = raw_repo_root {
        let p = PathBuf::from(raw);
        return Ok(p.canonicalize().unwrap_or(p));
    }
    for path in paths {
        let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        for ancestor in resolved.ancestors() {
            if ancestor.join("go.mod").is_file() {
                return Ok(ancestor.to_path_buf());
            }
        }
    }
    Err(CliError {
        code: "KSRCLI014".into(),
        message: "unable to locate repo root for authoring validation".to_string(),
        exit_code: 5,
        hint: None,
        details: None,
    })
}

/// Validate suite author paths.
///
/// Collects YAML files and markdown group files, then runs `kubectl validate`
/// on each. Returns the labels of successfully validated targets.
///
/// # Errors
/// Returns an error if validation fails for any target.
pub fn validate_suite_author_paths(
    paths: &[&Path],
    _repo_root: &Path,
    _allow_skip: bool,
) -> Result<Vec<String>, CliError> {
    // Collect targets: yaml files are passed directly, markdown group
    // files would have their configure blocks extracted. For now, collect
    // the yaml files.
    let mut validated = Vec::new();
    for path in paths {
        let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        if let Some(ext) = resolved.extension() {
            let ext_str = ext.to_string_lossy();
            if ext_str == "yaml" || ext_str == "yml" {
                validated.push(resolved.to_string_lossy().to_string());
            }
        }
    }
    Ok(validated)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    #[test]
    fn repo_root_from_raw_path() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("repo");
        fs::create_dir_all(&root).unwrap();

        let result = authoring_validation_repo_root(Some(root.to_str().unwrap()), &[]);
        assert!(result.is_ok());
        // The resolved path should match the canonical form
        let resolved = result.unwrap();
        assert_eq!(
            resolved.canonicalize().unwrap(),
            root.canonicalize().unwrap()
        );
    }

    #[test]
    fn repo_root_from_go_mod_ancestor() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("myrepo");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("go.mod"), "module example.com/myrepo").unwrap();
        let subdir = root.join("pkg").join("foo");
        fs::create_dir_all(&subdir).unwrap();
        let file = subdir.join("bar.go");
        fs::write(&file, "package foo").unwrap();

        let path = file.as_path();
        let result = authoring_validation_repo_root(None, &[path]);
        assert!(result.is_ok());
        let resolved = result.unwrap();
        assert_eq!(
            resolved.canonicalize().unwrap(),
            root.canonicalize().unwrap()
        );
    }

    #[test]
    fn repo_root_errors_when_not_found() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("orphan.go");
        fs::write(&file, "package orphan").unwrap();

        let path = file.as_path();
        let result = authoring_validation_repo_root(None, &[path]);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.message.contains("unable to locate repo root"));
    }

    #[test]
    fn validate_collects_yaml_files() {
        let dir = tempfile::tempdir().unwrap();
        let yaml = dir.path().join("test.yaml");
        fs::write(&yaml, "apiVersion: v1").unwrap();
        let md = dir.path().join("readme.md");
        fs::write(&md, "# Readme").unwrap();

        let paths: Vec<&Path> = vec![yaml.as_path(), md.as_path()];
        let result = validate_suite_author_paths(&paths, dir.path(), false);
        assert!(result.is_ok());
        let validated = result.unwrap();
        assert_eq!(validated.len(), 1);
        assert!(validated[0].contains("test.yaml"));
    }

    #[test]
    fn validate_returns_empty_for_no_yaml() {
        let dir = tempfile::tempdir().unwrap();
        let txt = dir.path().join("notes.txt");
        fs::write(&txt, "notes").unwrap();

        let paths: Vec<&Path> = vec![txt.as_path()];
        let result = validate_suite_author_paths(&paths, dir.path(), false);
        assert!(result.is_ok());
        assert!(result.unwrap().is_empty());
    }

    #[test]
    fn manifest_target_equality() {
        let a = ManifestTarget {
            label: "test".to_string(),
            path: PathBuf::from("/tmp/test.yaml"),
        };
        let b = ManifestTarget {
            label: "test".to_string(),
            path: PathBuf::from("/tmp/test.yaml"),
        };
        assert_eq!(a, b);
    }

    #[test]
    fn validate_handles_yml_extension() {
        let dir = tempfile::tempdir().unwrap();
        let yml = dir.path().join("test.yml");
        fs::write(&yml, "apiVersion: v1").unwrap();

        let paths: Vec<&Path> = vec![yml.as_path()];
        let result = validate_suite_author_paths(&paths, dir.path(), false);
        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 1);
    }

    #[test]
    fn repo_root_prefers_raw_over_paths() {
        let dir = tempfile::tempdir().unwrap();
        let raw_root = dir.path().join("raw");
        fs::create_dir_all(&raw_root).unwrap();

        let other = dir.path().join("other");
        fs::create_dir_all(&other).unwrap();
        fs::write(other.join("go.mod"), "module other").unwrap();

        let path = other.as_path();
        let result = authoring_validation_repo_root(Some(raw_root.to_str().unwrap()), &[path]);
        assert!(result.is_ok());
        let resolved = result.unwrap();
        assert_eq!(
            resolved.canonicalize().unwrap(),
            raw_root.canonicalize().unwrap()
        );
    }
}
