use super::*;
use harness::infra::blocks::DockerContainerRuntime;

fn production_runtime() -> DockerContainerRuntime {
    use harness::infra::blocks::StdProcessExecutor;
    use std::sync::Arc;
    DockerContainerRuntime::new(Arc::new(StdProcessExecutor))
}

#[test]
#[ignore] // needs Docker daemon
fn production_run_detached_returns_id() {
    contract_run_detached_returns_id(&production_runtime());
}

#[test]
#[ignore]
fn production_is_running_reflects_state() {
    contract_is_running_reflects_state(&production_runtime());
}

#[test]
#[ignore]
fn production_remove_is_idempotent() {
    contract_remove_is_idempotent(&production_runtime());
}

#[test]
#[ignore]
fn production_network_lifecycle() {
    contract_network_lifecycle(&production_runtime());
}
