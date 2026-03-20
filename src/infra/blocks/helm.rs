use std::collections::HashMap;
use std::path::Path;
#[cfg(feature = "helm")]
use std::sync::Arc;
#[cfg(test)]
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::infra::blocks::BlockError;
#[cfg(feature = "helm")]
use crate::infra::blocks::ProcessExecutor;
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

/// Generic package deployment port.
///
/// The current codebase still bootstraps most Kuma-on-k3d flows through
/// repository `make` targets rather than direct `helm` invocations. This trait
/// intentionally supports both shapes:
///
/// - `run_target()` preserves the current implementation strategy
/// - `upgrade_install()` provides the typed Helm-facing contract that callers
///   can migrate to incrementally
pub trait PackageDeployer: Send + Sync {
    /// Run a repository deployment target with environment overrides.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the target fails.
    fn run_target(
        &self,
        repo_root: &Path,
        target: &str,
        env: &HashMap<String, String>,
    ) -> Result<CommandResult, BlockError>;

    /// Run a live/inherited deployment target with environment overrides.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the target fails.
    fn run_target_live(
        &self,
        repo_root: &Path,
        target: &str,
        env: &HashMap<String, String>,
    ) -> Result<i32, BlockError>;

    /// Apply or upgrade a Helm release directly.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the Helm command fails.
    fn upgrade_install(
        &self,
        release: &str,
        chart: &str,
        namespace: Option<&str>,
        settings: &[HelmSetting],
        extra_args: &[&str],
    ) -> Result<PackageDeployResult, BlockError>;

    /// Uninstall a Helm release directly.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the Helm command fails.
    fn uninstall(
        &self,
        release: &str,
        namespace: Option<&str>,
        extra_args: &[&str],
    ) -> Result<CommandResult, BlockError>;
}

/// Production package deployer backed by a process executor.
///
/// This implementation preserves the repository's current deployment model:
/// many callers still invoke `make` targets that encapsulate Helm logic.
#[cfg(feature = "helm")]
pub struct HelmDeployer {
    process: Arc<dyn ProcessExecutor>,
}

#[cfg(feature = "helm")]
impl HelmDeployer {
    #[must_use]
    pub fn new(process: Arc<dyn ProcessExecutor>) -> Self {
        Self { process }
    }

    fn helm(&self, args: &[&str], ok_exit_codes: &[i32]) -> Result<CommandResult, BlockError> {
        let mut command = vec!["helm"];
        command.extend_from_slice(args);
        self.process.run(&command, None, None, ok_exit_codes)
    }

    fn settings_args(settings: &[HelmSetting]) -> Vec<String> {
        let mut args = Vec::with_capacity(settings.len() * 2);
        for setting in settings {
            args.push("--set".to_string());
            args.push(setting.to_cli_arg());
        }
        args
    }
}

#[cfg(feature = "helm")]
impl PackageDeployer for HelmDeployer {
    fn run_target(
        &self,
        repo_root: &Path,
        target: &str,
        env: &HashMap<String, String>,
    ) -> Result<CommandResult, BlockError> {
        self.process
            .run(&["make", target], Some(repo_root), Some(env), &[0])
            .map_err(|error| {
                BlockError::message("helm", &format!("run_target {target}"), error.to_string())
            })
    }

    fn run_target_live(
        &self,
        repo_root: &Path,
        target: &str,
        env: &HashMap<String, String>,
    ) -> Result<i32, BlockError> {
        self.process
            .run_inherited(&["make", target], Some(repo_root), Some(env), &[0])
            .map_err(|error| {
                BlockError::message(
                    "helm",
                    &format!("run_target_live {target}"),
                    error.to_string(),
                )
            })
    }

    fn upgrade_install(
        &self,
        release: &str,
        chart: &str,
        namespace: Option<&str>,
        settings: &[HelmSetting],
        extra_args: &[&str],
    ) -> Result<PackageDeployResult, BlockError> {
        let mut args = vec!["upgrade", "--install", release, chart];
        let namespace_value = namespace.map(ToOwned::to_owned);
        if let Some(namespace) = namespace {
            args.push("--namespace");
            args.push(namespace);
            args.push("--create-namespace");
        }

        let settings_args = Self::settings_args(settings);
        for item in &settings_args {
            args.push(item.as_str());
        }
        args.extend_from_slice(extra_args);

        let command = self.helm(&args, &[0])?;
        Ok(PackageDeployResult {
            release: release.to_string(),
            namespace: namespace_value,
            chart: chart.to_string(),
            applied_settings: settings.to_vec(),
            command,
        })
    }

    fn uninstall(
        &self,
        release: &str,
        namespace: Option<&str>,
        extra_args: &[&str],
    ) -> Result<CommandResult, BlockError> {
        let mut args = vec!["uninstall", release];
        if let Some(namespace) = namespace {
            args.push("--namespace");
            args.push(namespace);
        }
        args.extend_from_slice(extra_args);
        self.helm(&args, &[0, 1])
    }
}

#[cfg(test)]
#[derive(Debug, Default)]
pub struct FakePackageDeployer {
    targets: Mutex<Vec<String>>,
    releases: Mutex<HashMap<String, Vec<HelmSetting>>>,
}

#[cfg(test)]
impl FakePackageDeployer {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

#[cfg(test)]
impl PackageDeployer for FakePackageDeployer {
    fn run_target(
        &self,
        _repo_root: &Path,
        target: &str,
        _env: &HashMap<String, String>,
    ) -> Result<CommandResult, BlockError> {
        self.targets
            .lock()
            .expect("lock poisoned")
            .push(target.to_string());
        Ok(CommandResult {
            args: vec!["make".into(), target.into()],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }

    fn run_target_live(
        &self,
        _repo_root: &Path,
        target: &str,
        _env: &HashMap<String, String>,
    ) -> Result<i32, BlockError> {
        self.targets
            .lock()
            .expect("lock poisoned")
            .push(format!("live:{target}"));
        Ok(0)
    }

    fn upgrade_install(
        &self,
        release: &str,
        chart: &str,
        namespace: Option<&str>,
        settings: &[HelmSetting],
        _extra_args: &[&str],
    ) -> Result<PackageDeployResult, BlockError> {
        self.releases
            .lock()
            .expect("lock poisoned")
            .insert(release.to_string(), settings.to_vec());
        Ok(PackageDeployResult {
            release: release.to_string(),
            namespace: namespace.map(ToOwned::to_owned),
            chart: chart.to_string(),
            applied_settings: settings.to_vec(),
            command: CommandResult {
                args: vec![
                    "helm".into(),
                    "upgrade".into(),
                    "--install".into(),
                    release.into(),
                    chart.into(),
                ],
                returncode: 0,
                stdout: String::new(),
                stderr: String::new(),
            },
        })
    }

    fn uninstall(
        &self,
        release: &str,
        _namespace: Option<&str>,
        _extra_args: &[&str],
    ) -> Result<CommandResult, BlockError> {
        self.releases.lock().expect("lock poisoned").remove(release);
        Ok(CommandResult {
            args: vec!["helm".into(), "uninstall".into(), release.into()],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }
}

#[cfg(test)]
mod tests;
