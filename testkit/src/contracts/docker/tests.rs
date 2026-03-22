use super::*;
use harness::infra::blocks::{BollardContainerRuntime, DockerContainerRuntime};

fn production_runtime() -> DockerContainerRuntime {
    use harness::infra::blocks::StdProcessExecutor;
    use std::sync::Arc;
    DockerContainerRuntime::new(Arc::new(StdProcessExecutor))
}

fn production_bollard_runtime() -> BollardContainerRuntime {
    BollardContainerRuntime::new().expect("expected Docker engine connection")
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

#[test]
#[ignore] // needs Docker daemon
fn production_bollard_run_detached_returns_id() {
    contract_run_detached_returns_id(&production_bollard_runtime());
}

#[test]
#[ignore]
fn production_bollard_is_running_reflects_state() {
    contract_is_running_reflects_state(&production_bollard_runtime());
}

#[test]
#[ignore]
fn production_bollard_remove_is_idempotent() {
    contract_remove_is_idempotent(&production_bollard_runtime());
}

#[test]
#[ignore]
fn production_bollard_network_lifecycle() {
    contract_network_lifecycle(&production_bollard_runtime());
}
