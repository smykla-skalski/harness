use std::collections::HashMap;
use std::path::Path;

use crate::infra::blocks::BlockError;
use crate::infra::exec::CommandResult;

#[path = "helm/contract.rs"]
mod contract;
#[cfg(test)]
#[path = "helm/fake.rs"]
mod fake;
#[cfg(feature = "helm")]
#[path = "helm/runtime.rs"]
mod runtime;

pub use contract::{HelmSetting, PackageDeployResult};
#[cfg(test)]
pub use fake::FakePackageDeployer;
#[cfg(feature = "helm")]
pub use runtime::HelmDeployer;

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

#[cfg(test)]
mod tests;
