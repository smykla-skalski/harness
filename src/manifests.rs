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
mod tests {}
