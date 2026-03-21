use super::*;
use harness::infra::blocks::HelmDeployer;

fn production_deployer() -> HelmDeployer {
    use harness::infra::blocks::StdProcessExecutor;
    use std::sync::Arc;
    HelmDeployer::new(Arc::new(StdProcessExecutor))
}

#[test]
#[ignore] // needs Helm on PATH
fn production_uninstall_nonexistent_is_tolerant() {
    contract_uninstall_nonexistent_is_tolerant(&production_deployer());
}
