use super::*;
use harness::infra::blocks::ProcessBuildSystem;

fn production_build() -> ProcessBuildSystem {
    use harness::infra::blocks::StdProcessExecutor;
    use std::sync::Arc;
    ProcessBuildSystem::new(Arc::new(StdProcessExecutor))
}

#[test]
#[ignore] // needs make on PATH
fn production_name_is_non_empty() {
    contract_name_is_non_empty(&production_build());
}

#[test]
#[ignore]
fn production_denied_binaries_is_stable() {
    contract_denied_binaries_is_stable(&production_build());
}

#[test]
#[ignore]
fn production_run_target_does_not_panic() {
    contract_run_target_does_not_panic(&production_build());
}
