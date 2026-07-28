use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// Environment variables for command execution within a run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandEnv {
    pub profile: String,
    pub repo_root: String,
    pub run_dir: String,
    pub run_id: String,
    pub run_root: String,
    pub suite_dir: String,
    pub suite_id: String,
    pub suite_path: String,
    #[serde(default)]
    pub kubeconfig: Option<String>,
    /// "kubernetes" or "universal".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    /// CP REST API URL (universal mode only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp_api_url: Option<String>,
    /// Docker network name (universal mode only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub docker_network: Option<String>,
}

impl CommandEnv {
    pub fn iter_env_vars(&self) -> impl Iterator<Item = (&'static str, &str)> {
        [
            ("PROFILE", Some(self.profile.as_str())),
            ("REPO_ROOT", Some(self.repo_root.as_str())),
            ("RUN_DIR", Some(self.run_dir.as_str())),
            ("RUN_ID", Some(self.run_id.as_str())),
            ("RUN_ROOT", Some(self.run_root.as_str())),
            ("SUITE_DIR", Some(self.suite_dir.as_str())),
            ("SUITE_ID", Some(self.suite_id.as_str())),
            ("SUITE_PATH", Some(self.suite_path.as_str())),
            ("KUBECONFIG", self.kubeconfig.as_deref()),
            ("PLATFORM", self.platform.as_deref()),
            ("CP_API_URL", self.cp_api_url.as_deref()),
            ("DOCKER_NETWORK", self.docker_network.as_deref()),
        ]
        .into_iter()
        .filter_map(|(key, value)| value.map(|value| (key, value)))
    }

    /// Convert to a map of environment variable names to values.
    ///
    /// Returns owned strings because `Command::envs()` needs `AsRef<OsStr>`
    /// values that outlive the iterator. A `HashMap<&str, &str>` would work
    /// if callers only read the map, but the primary use case is feeding
    /// env vars to child processes, so owned strings are the right fit.
    #[must_use]
    pub fn to_env_dict(&self) -> HashMap<String, String> {
        self.iter_env_vars()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect()
    }
}
