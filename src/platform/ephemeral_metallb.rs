use std::fs;
use std::path::{Path, PathBuf};

use walkdir::WalkDir;

use crate::core_defs::utc_now;
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{is_safe_name, write_json_pretty};

const STATE_FILE: &str = "ephemeral-metallb-templates.json";
const DEFAULT_TEMPLATE_BASENAME: &str = "metallb-k3d-kuma.yaml";

/// State path for ephemeral `MetalLB` config.
#[must_use]
pub fn state_path(run_dir: &Path) -> PathBuf {
    run_dir.join("state").join(STATE_FILE)
}

/// Template path for a cluster.
///
/// # Errors
/// Returns `CliError` if `cluster_name` contains path separators or `..`.
pub fn template_path(root: &Path, cluster_name: &str) -> Result<PathBuf, CliError> {
    if !is_safe_name(cluster_name) {
        return Err(CliErrorKind::unsafe_name(cluster_name.to_string()).into());
    }
    Ok(root
        .join("mk")
        .join(format!("metallb-k3d-{cluster_name}.yaml")))
}

/// Default source template path.
fn default_source_template(root: &Path) -> Result<PathBuf, CliError> {
    let default = root.join("mk").join(DEFAULT_TEMPLATE_BASENAME);
    if default.is_file() {
        return Ok(default);
    }
    // Try any metallb-k3d-*.yaml in mk/
    let mk_dir = root.join("mk");
    if mk_dir.is_dir() {
        let mut templates: Vec<PathBuf> = WalkDir::new(&mk_dir)
            .min_depth(1)
            .max_depth(1)
            .sort_by_file_name()
            .into_iter()
            .filter_map(Result::ok)
            .map(walkdir::DirEntry::into_path)
            .filter(|p| {
                p.file_name().and_then(|n| n.to_str()).is_some_and(|n| {
                    n.starts_with("metallb-k3d-")
                        && Path::new(n)
                            .extension()
                            .is_some_and(|ext| ext.eq_ignore_ascii_case("yaml"))
                })
            })
            .collect();
        templates.sort();
        if let Some(first) = templates.into_iter().next() {
            return Ok(first);
        }
    }
    Err(CliErrorKind::missing_file(default.to_string_lossy().into_owned()).into())
}

/// Ensure `MetalLB` templates exist for the given clusters.
///
/// Copies the default template for each missing cluster-specific template.
/// Records created entries in the run state file.
///
/// # Errors
/// Returns `CliError` if the default source template is missing or on IO failure.
pub fn ensure_templates(
    root: &Path,
    cluster_names: &[&str],
    run_dir: Option<&Path>,
) -> Result<Vec<PathBuf>, CliError> {
    let mut created = Vec::new();
    let mut entries = load_entries(run_dir)?;
    let source = default_source_template(root)?;

    for cluster_name in cluster_names {
        let target = template_path(root, cluster_name)?;
        if target.exists() {
            continue;
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(&source, &target)?;
        created.push(target.clone());

        let entry = serde_json::json!({
            "cluster_name": cluster_name,
            "created_at": utc_now(),
            "source_path": source.to_string_lossy(),
            "template_path": target.to_string_lossy(),
        });
        entries.push(entry);
    }

    if let Some(rd) = run_dir
        && !entries.is_empty()
    {
        save_entries(rd, &entries)?;
    }

    Ok(created)
}

/// Cleanup `MetalLB` templates that were created by `ensure_templates`.
///
/// Removes the template files and optionally removes the state file.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn cleanup_templates(run_dir: &Path) -> Result<Vec<PathBuf>, CliError> {
    let entries = load_entries(Some(run_dir))?;
    if entries.is_empty() {
        return Ok(vec![]);
    }

    let mut removed = Vec::new();
    for entry in &entries {
        if let Some(tp) = entry.get("template_path").and_then(|v| v.as_str()) {
            let template = PathBuf::from(tp);
            if template.exists() {
                fs::remove_file(&template)?;
                removed.push(template);
            }
        }
    }

    Ok(removed)
}

/// Restore `MetalLB` templates from state for a pending run.
///
/// # Errors
/// Returns `CliError` on IO failure or missing source.
pub fn restore_templates(run_dir: &Path) -> Result<Vec<PathBuf>, CliError> {
    let entries = load_entries(Some(run_dir))?;
    if entries.is_empty() {
        return Ok(vec![]);
    }

    let mut restored = Vec::new();
    for entry in &entries {
        let source_str = entry
            .get("source_path")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let target_str = entry
            .get("template_path")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if source_str.is_empty() || target_str.is_empty() {
            continue;
        }
        let source = PathBuf::from(source_str);
        let target = PathBuf::from(target_str);

        if target.exists() {
            continue;
        }
        if !source.is_file() {
            return Err(CliErrorKind::missing_file(source_str.to_string()).into());
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(&source, &target)?;
        restored.push(target);
    }

    Ok(restored)
}

fn load_entries(run_dir: Option<&Path>) -> Result<Vec<serde_json::Value>, CliError> {
    let Some(rd) = run_dir else {
        return Ok(vec![]);
    };
    let path = state_path(rd);
    if !path.is_file() {
        return Ok(vec![]);
    }
    let text = fs::read_to_string(&path)
        .map_err(|e| CliErrorKind::io(format!("{}: {e}", path.display())))?;
    let payload: serde_json::Value = serde_json::from_str(&text).map_err(|e| {
        CliErrorKind::invalid_json(path.display().to_string()).with_details(e.to_string())
    })?;
    Ok(payload
        .get("entries")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default())
}

fn save_entries(run_dir: &Path, entries: &[serde_json::Value]) -> Result<(), CliError> {
    let path = state_path(run_dir);
    let payload = serde_json::json!({
        "schema_version": 1,
        "entries": entries,
    });
    write_json_pretty(&path, &payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_path_includes_state_dir() {
        let path = state_path(Path::new("/runs/r1"));
        assert_eq!(
            path,
            PathBuf::from("/runs/r1/state/ephemeral-metallb-templates.json")
        );
    }

    #[test]
    fn template_path_formats_cluster_name() {
        let path = template_path(Path::new("/repo"), "kuma-1").unwrap();
        assert_eq!(path, PathBuf::from("/repo/mk/metallb-k3d-kuma-1.yaml"));
    }

    #[test]
    fn template_path_rejects_traversal() {
        let err = template_path(Path::new("/repo"), "../evil").unwrap_err();
        assert_eq!(err.code(), "KSRCLI059");
    }

    #[test]
    fn template_path_rejects_slash() {
        let err = template_path(Path::new("/repo"), "a/b").unwrap_err();
        assert_eq!(err.code(), "KSRCLI059");
    }

    #[test]
    fn ensure_templates_creates_copies() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mk = root.join("mk");
        fs::create_dir_all(&mk).unwrap();
        fs::write(mk.join(DEFAULT_TEMPLATE_BASENAME), "template content").unwrap();

        let run_dir = dir.path().join("run");
        fs::create_dir_all(&run_dir).unwrap();

        let created = ensure_templates(root, &["c1", "c2"], Some(&run_dir)).unwrap();

        assert_eq!(created.len(), 2);
        for path in &created {
            assert!(path.exists());
            assert_eq!(fs::read_to_string(path).unwrap(), "template content");
        }
    }

    #[test]
    fn ensure_templates_skips_existing() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mk = root.join("mk");
        fs::create_dir_all(&mk).unwrap();
        fs::write(mk.join(DEFAULT_TEMPLATE_BASENAME), "base").unwrap();
        fs::write(mk.join("metallb-k3d-existing.yaml"), "already here").unwrap();

        let created = ensure_templates(root, &["existing"], None).unwrap();
        assert!(created.is_empty());
    }

    #[test]
    fn ensure_templates_records_state() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mk = root.join("mk");
        fs::create_dir_all(&mk).unwrap();
        fs::write(mk.join(DEFAULT_TEMPLATE_BASENAME), "base").unwrap();

        let run_dir = dir.path().join("run");
        fs::create_dir_all(&run_dir).unwrap();

        ensure_templates(root, &["c1"], Some(&run_dir)).unwrap();
        assert!(state_path(&run_dir).exists());
    }

    #[test]
    fn cleanup_templates_removes_created_files() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mk = root.join("mk");
        fs::create_dir_all(&mk).unwrap();
        fs::write(mk.join(DEFAULT_TEMPLATE_BASENAME), "base").unwrap();

        let run_dir = dir.path().join("run");
        fs::create_dir_all(&run_dir).unwrap();

        let created = ensure_templates(root, &["local"], Some(&run_dir)).unwrap();
        assert_eq!(created.len(), 1);
        assert!(created[0].exists());

        let removed = cleanup_templates(&run_dir).unwrap();
        assert_eq!(removed.len(), 1);
        assert!(!created[0].exists());
    }

    #[test]
    fn cleanup_templates_returns_empty_when_no_state() {
        let dir = tempfile::tempdir().unwrap();
        let removed = cleanup_templates(dir.path()).unwrap();
        assert!(removed.is_empty());
    }

    #[test]
    fn restore_templates_recreates_from_source() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mk = root.join("mk");
        fs::create_dir_all(&mk).unwrap();
        fs::write(mk.join(DEFAULT_TEMPLATE_BASENAME), "base").unwrap();

        let run_dir = dir.path().join("run");
        fs::create_dir_all(&run_dir).unwrap();

        let created = ensure_templates(root, &["restore-test"], Some(&run_dir)).unwrap();
        assert_eq!(created.len(), 1);

        // Remove the template but keep the state
        fs::remove_file(&created[0]).unwrap();
        assert!(!created[0].exists());

        let restored = restore_templates(&run_dir).unwrap();
        assert_eq!(restored.len(), 1);
        assert!(created[0].exists());
    }

    #[test]
    fn restore_templates_skips_already_existing() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mk = root.join("mk");
        fs::create_dir_all(&mk).unwrap();
        fs::write(mk.join(DEFAULT_TEMPLATE_BASENAME), "base").unwrap();

        let run_dir = dir.path().join("run");
        fs::create_dir_all(&run_dir).unwrap();

        ensure_templates(root, &["skip-test"], Some(&run_dir)).unwrap();

        // Don't remove - template still exists
        let restored = restore_templates(&run_dir).unwrap();
        assert!(restored.is_empty());
    }

    #[test]
    fn load_entries_propagates_corrupt_state() {
        let dir = tempfile::tempdir().unwrap();
        let run_dir = dir.path().join("run");
        let state_dir = run_dir.join("state");
        fs::create_dir_all(&state_dir).unwrap();
        fs::write(state_dir.join(STATE_FILE), "not json {").unwrap();
        let err = load_entries(Some(&run_dir)).unwrap_err();
        assert_eq!(err.code(), "KSRCLI019");
    }

    #[test]
    fn ensure_templates_fails_when_no_source() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let err = ensure_templates(root, &["c1"], None).unwrap_err();
        assert_eq!(err.code(), "KSRCLI014");
    }

    #[test]
    fn default_source_template_finds_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let mk = dir.path().join("mk");
        fs::create_dir_all(&mk).unwrap();
        fs::write(mk.join("metallb-k3d-custom.yaml"), "custom").unwrap();

        let source = default_source_template(dir.path()).unwrap();
        assert!(source.to_string_lossy().contains("metallb-k3d-custom.yaml"));
    }
}
