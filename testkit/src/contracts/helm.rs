use std::collections::HashMap;
use std::path::Path;

use harness::blocks::PackageDeployer;

/// `run_target` with a valid make target returns a result.
///
/// # Panics
/// Panics if the target execution fails.
pub fn contract_run_target_returns_result(
    deployer: &dyn PackageDeployer,
    repo_root: &Path,
    target: &str,
) {
    let result = deployer
        .run_target(repo_root, target, &HashMap::new())
        .expect("run_target should succeed");
    assert_eq!(result.returncode, 0);
}

/// `upgrade_install` with a valid chart returns a deploy result.
///
/// # Panics
/// Panics if the upgrade/install operation fails.
pub fn contract_upgrade_install_returns_deploy_result(deployer: &dyn PackageDeployer) {
    let result = deployer
        .upgrade_install(
            "contract-test",
            "oci://example/chart",
            None,
            &[],
            &["--dry-run"],
        )
        .expect("upgrade_install should succeed");
    assert_eq!(result.release, "contract-test");
    assert_eq!(result.chart, "oci://example/chart");
}

/// `uninstall` for a non-existent release does not panic.
pub fn contract_uninstall_nonexistent_is_tolerant(deployer: &dyn PackageDeployer) {
    let _ = deployer.uninstall("nonexistent-contract-test-release", None, &[]);
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness::blocks::HelmDeployer;

    fn production_deployer() -> HelmDeployer {
        use harness::blocks::StdProcessExecutor;
        use std::sync::Arc;
        HelmDeployer::new(Arc::new(StdProcessExecutor))
    }

    #[test]
    #[ignore] // needs Helm on PATH
    fn production_uninstall_nonexistent_is_tolerant() {
        contract_uninstall_nonexistent_is_tolerant(&production_deployer());
    }
}
