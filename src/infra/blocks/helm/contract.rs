use serde::{Deserialize, Serialize};

use crate::infra::exec::CommandResult;

/// A single Helm setting (`key=value`) passed through to a deployment target.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HelmSetting {
    pub key: String,
    pub value: String,
}

impl HelmSetting {
    /// Parse a `key=value` CLI argument into a structured setting.
    ///
    /// # Errors
    ///
    /// Returns an error string when the input does not contain a non-empty key.
    pub fn from_cli_arg(raw: &str) -> Result<Self, String> {
        let (key, value) = raw
            .split_once('=')
            .filter(|(key, _)| !key.is_empty())
            .ok_or_else(|| format!("invalid --helm-setting value: {raw}"))?;
        Ok(Self {
            key: key.to_string(),
            value: value.to_string(),
        })
    }

    #[must_use]
    pub fn to_cli_arg(&self) -> String {
        format!("{}={}", self.key, self.value)
    }
}

/// Result of a package deployment action.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageDeployResult {
    pub release: String,
    pub namespace: Option<String>,
    pub chart: String,
    pub applied_settings: Vec<HelmSetting>,
    pub command: CommandResult,
}
