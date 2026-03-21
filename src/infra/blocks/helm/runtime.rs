use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use crate::infra::blocks::{BlockError, ProcessExecutor};
use crate::infra::exec::CommandResult;

use super::{HelmSetting, PackageDeployResult, PackageDeployer};

/// Production package deployer backed by a process executor.
///
/// This implementation preserves the repository's current deployment model:
/// many callers still invoke `make` targets that encapsulate Helm logic.
pub struct HelmDeployer {
    process: Arc<dyn ProcessExecutor>,
}

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
