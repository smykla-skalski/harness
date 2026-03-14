use std::path::{Path, PathBuf};

/// Default validation output path for a manifest.
#[must_use]
pub fn default_validation_output(manifest: &Path) -> PathBuf {
    manifest.with_extension("validation.json")
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
