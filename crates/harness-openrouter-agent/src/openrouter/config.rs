//! Configuration for the OpenRouter ACP shim.
//!
//! The API key reaches the shim through a one-shot credential file whose path
//! the daemon supplies via `--api-key-file PATH`. The daemon creates the file
//! with mode 0600 in a per-spawn random directory, writes the key from its
//! Monitor-synced in-memory token cache, and the shim reads then immediately
//! unlinks the file. Environment variables are deliberately NOT a delivery
//! channel — they leak to grand-children and show up in `/proc/<pid>/environ`,
//! which is the wrong threat model for an API credential.
//!
//! Non-secret tuning (base URL, referer, title) is still read from environment
//! variables — those values aren't secrets and routinely need to be overridden
//! for local proxying or branding.

use std::env;
use std::io::ErrorKind;
use std::path::Path;

use thiserror::Error;

const DEFAULT_BASE_URL: &str = "https://openrouter.ai/api/v1";
const DEFAULT_HTTP_REFERER: &str = "https://harness.dev";
const DEFAULT_X_TITLE: &str = "Harness";

#[derive(Debug, Clone)]
pub struct AgentConfig {
    pub api_key: String,
    pub base_url: String,
    pub http_referer: String,
    pub x_title: String,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error(
        "OpenRouter API key file was not supplied. The daemon must launch the shim with `--api-key-file PATH`. If you are running the shim manually, write the key to a mode-0600 file and pass its path."
    )]
    MissingApiKeyFile,
    #[error("OpenRouter API key file `{path}` is empty after trimming")]
    EmptyApiKeyFile { path: String },
    #[error("failed to read api-key-file `{path}`: {source}")]
    ApiKeyFile {
        path: String,
        #[source]
        source: std::io::Error,
    },
}

impl AgentConfig {
    /// Read the API key from `path` (the file the daemon prepared) and layer
    /// non-secret tuning from the process environment.
    ///
    /// # Errors
    /// Returns [`ConfigError::ApiKeyFile`] when the file can't be opened,
    /// or [`ConfigError::EmptyApiKeyFile`] when the trimmed contents are
    /// empty.
    pub fn from_api_key_file(path: &Path) -> Result<Self, ConfigError> {
        let raw = std::fs::read_to_string(path).map_err(|source| ConfigError::ApiKeyFile {
            path: path.display().to_string(),
            source,
        })?;
        let api_key = raw.trim().to_owned();
        if api_key.is_empty() {
            return Err(ConfigError::EmptyApiKeyFile {
                path: path.display().to_string(),
            });
        }
        Ok(Self {
            api_key,
            base_url: env_string("OPENROUTER_API_URL")
                .unwrap_or_else(|| DEFAULT_BASE_URL.to_owned()),
            http_referer: env_string("OPENROUTER_HTTP_REFERER")
                .unwrap_or_else(|| DEFAULT_HTTP_REFERER.to_owned()),
            x_title: env_string("OPENROUTER_X_TITLE").unwrap_or_else(|| DEFAULT_X_TITLE.to_owned()),
        })
    }

    /// Build the agent config from an arbitrary source. Exposed so the unit
    /// suite doesn't have to touch the filesystem.
    ///
    /// # Errors
    /// Returns [`ConfigError::MissingApiKeyFile`] when the API key is empty
    /// or absent.
    pub fn from_source<F: Fn(&str) -> Option<String>>(read: F) -> Result<Self, ConfigError> {
        let api_key = read("OPENROUTER_API_KEY")
            .filter(|value| !value.is_empty())
            .ok_or(ConfigError::MissingApiKeyFile)?;
        Ok(Self {
            api_key,
            base_url: read("OPENROUTER_API_URL")
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| DEFAULT_BASE_URL.to_owned()),
            http_referer: read("OPENROUTER_HTTP_REFERER")
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| DEFAULT_HTTP_REFERER.to_owned()),
            x_title: read("OPENROUTER_X_TITLE")
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| DEFAULT_X_TITLE.to_owned()),
        })
    }
}

/// Unlink the credential file. Called by the shim after [`AgentConfig::from_api_key_file`]
/// so the key never lingers on disk longer than one stat() interval.
///
/// Managed credential directories are removed too. Errors are logged at warn
/// level and not propagated because the daemon retains an independent RAII
/// cleanup guard until protocol initialization finishes.
pub fn discard_api_key_file(path: &Path) {
    match std::fs::remove_file(path) {
        Ok(()) => remove_managed_credential_directory(path),
        Err(error) if error.kind() == ErrorKind::NotFound => {
            remove_managed_credential_directory(path);
        }
        Err(error) => {
            tracing::warn!(
                path = %path.display(),
                %error,
                "failed to unlink api-key-file after read"
            );
        }
    }
}

fn remove_managed_credential_directory(path: &Path) {
    let Some(parent) = path.parent().filter(|parent| {
        path.file_name().is_some_and(|name| name == "api-key")
            && parent
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("harness-openrouter-"))
    }) else {
        return;
    };
    match std::fs::remove_dir(parent) {
        Ok(()) => {}
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::NotFound | ErrorKind::DirectoryNotEmpty
            ) => {}
        Err(error) => tracing::warn!(
            path = %parent.display(),
            %error,
            "failed to remove managed api-key directory after read"
        ),
    }
}

fn env_string(name: &str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_apply_when_only_api_key_is_set() {
        let config = AgentConfig::from_source(|name| match name {
            "OPENROUTER_API_KEY" => Some("sk-test".to_owned()),
            _ => None,
        })
        .expect("config from source");
        assert_eq!(config.api_key, "sk-test");
        assert_eq!(config.base_url, DEFAULT_BASE_URL);
        assert_eq!(config.http_referer, DEFAULT_HTTP_REFERER);
        assert_eq!(config.x_title, DEFAULT_X_TITLE);
    }

    #[test]
    fn missing_api_key_is_an_error() {
        let err = AgentConfig::from_source(|_| None).expect_err("missing key should error");
        assert!(matches!(err, ConfigError::MissingApiKeyFile));
    }

    #[test]
    fn empty_api_key_is_treated_as_missing() {
        let err = AgentConfig::from_source(|name| {
            if name == "OPENROUTER_API_KEY" {
                Some(String::new())
            } else {
                None
            }
        })
        .expect_err("empty key should error");
        assert!(matches!(err, ConfigError::MissingApiKeyFile));
    }

    #[test]
    fn custom_base_url_is_honored() {
        let config = AgentConfig::from_source(|name| match name {
            "OPENROUTER_API_KEY" => Some("sk-test".to_owned()),
            "OPENROUTER_API_URL" => Some("https://example.test/v1".to_owned()),
            _ => None,
        })
        .expect("config from source");
        assert_eq!(config.base_url, "https://example.test/v1");
    }

    #[test]
    fn from_api_key_file_loads_trimmed_key() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("openrouter-key");
        std::fs::write(&path, "  sk-test-file\n").expect("write key file");
        let config = AgentConfig::from_api_key_file(&path).expect("from file");
        assert_eq!(config.api_key, "sk-test-file");
    }

    #[test]
    fn empty_api_key_file_is_missing() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("openrouter-key");
        std::fs::write(&path, " \n  \n").expect("write key file");
        let err = AgentConfig::from_api_key_file(&path).expect_err("empty file should error");
        assert!(matches!(err, ConfigError::EmptyApiKeyFile { .. }));
    }

    #[test]
    fn missing_api_key_file_surfaces_io_error() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("does-not-exist");
        let err = AgentConfig::from_api_key_file(&path).expect_err("missing file should error");
        assert!(matches!(err, ConfigError::ApiKeyFile { .. }));
    }

    #[test]
    fn discard_api_key_file_unlinks() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("ephemeral-key");
        std::fs::write(&path, "sk-ephemeral").expect("write");
        assert!(path.exists());
        discard_api_key_file(&path);
        assert!(!path.exists());
        assert!(dir.path().exists());
    }

    #[test]
    fn discard_api_key_file_removes_managed_directory() {
        let dir = tempfile::Builder::new()
            .prefix("harness-openrouter-")
            .tempdir()
            .expect("tempdir");
        let directory = dir.path().to_path_buf();
        let path = directory.join("api-key");
        std::fs::write(&path, "sk-ephemeral").expect("write");

        discard_api_key_file(&path);

        assert!(!path.exists());
        assert!(!directory.exists());
    }
}
