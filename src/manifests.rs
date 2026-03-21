use std::path::{Path, PathBuf};

/// Default validation output path for a manifest.
#[must_use]
pub fn default_validation_output(manifest: &Path) -> PathBuf {
    manifest.with_extension("validation.json")
}

#[cfg(test)]
#[path = "manifests/tests.rs"]
mod tests;
