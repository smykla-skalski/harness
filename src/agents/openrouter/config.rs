//! Environment-derived configuration for the `OpenRouter` agent backend.
//!
//! Reads `OPENROUTER_*` variables at the time the daemon spins up an
//! `OpenRouter` session. Values are immutable for the session's lifetime; a
//! new session re-reads the environment.

use std::env;

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
    #[error("OPENROUTER_API_KEY environment variable is empty or unset")]
    MissingApiKey,
}

impl AgentConfig {
    /// Build the agent config from `OPENROUTER_*` environment variables.
    ///
    /// # Errors
    /// Returns [`ConfigError::MissingApiKey`] when the API key is empty or
    /// absent.
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_source(|name| env::var(name).ok())
    }

    /// Build the agent config from an arbitrary source. Exposed for tests so
    /// the unit suite doesn't have to mutate process-wide env state.
    ///
    /// # Errors
    /// Returns [`ConfigError::MissingApiKey`] when the API key is empty or
    /// absent.
    pub fn from_source<F: Fn(&str) -> Option<String>>(read: F) -> Result<Self, ConfigError> {
        let api_key = read("OPENROUTER_API_KEY")
            .filter(|value| !value.is_empty())
            .ok_or(ConfigError::MissingApiKey)?;
        let base_url = read("OPENROUTER_API_URL")
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| DEFAULT_BASE_URL.to_owned());
        let http_referer = read("OPENROUTER_HTTP_REFERER")
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| DEFAULT_HTTP_REFERER.to_owned());
        let x_title = read("OPENROUTER_X_TITLE")
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| DEFAULT_X_TITLE.to_owned());
        Ok(Self {
            api_key,
            base_url,
            http_referer,
            x_title,
        })
    }
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
        assert!(matches!(err, ConfigError::MissingApiKey));
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
        assert!(matches!(err, ConfigError::MissingApiKey));
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
}
