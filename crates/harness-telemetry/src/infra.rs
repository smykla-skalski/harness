pub mod io {
    use std::fs;
    use std::path::Path;

    #[cfg(test)]
    use serde::Serialize;
    use serde::de::DeserializeOwned;

    use crate::errors::{CliError, CliErrorKind};

    /// Read and deserialize one JSON document.
    ///
    /// # Errors
    /// Returns an error when the file cannot be read or decoded.
    pub fn read_json_typed<T: DeserializeOwned>(path: &Path) -> Result<T, CliError> {
        let bytes = fs::read(path).map_err(|error| {
            CliErrorKind::workflow_io(format!("read {}: {error}", path.display()))
        })?;
        serde_json::from_slice(&bytes).map_err(|error| {
            CliErrorKind::workflow_parse(format!("parse {}: {error}", path.display())).into()
        })
    }

    #[cfg(test)]
    /// Serialize and write one indented JSON document.
    ///
    /// # Errors
    /// Returns an error when the parent directory, serialization, or write fails.
    pub fn write_json_pretty<T: Serialize>(path: &Path, value: &T) -> Result<(), CliError> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let bytes = serde_json::to_vec_pretty(value).map_err(|error| {
            CliErrorKind::workflow_parse(format!("serialize {}: {error}", path.display()))
        })?;
        fs::write(path, bytes)?;
        Ok(())
    }
}
