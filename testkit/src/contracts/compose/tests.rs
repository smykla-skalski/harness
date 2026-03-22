use super::*;
use harness::infra::blocks::{
    BollardComposeOrchestrator, BollardContainerRuntime, DockerComposeOrchestrator,
};

fn production_orchestrator() -> DockerComposeOrchestrator {
    use harness::infra::blocks::StdProcessExecutor;
    use std::sync::Arc;
    DockerComposeOrchestrator::new(Arc::new(StdProcessExecutor))
}

fn production_bollard_orchestrator() -> BollardComposeOrchestrator {
    use std::sync::Arc;
    let docker = Arc::new(BollardContainerRuntime::new().expect("expected Docker engine"));
    BollardComposeOrchestrator::new(docker)
}

#[test]
#[ignore] // needs Docker daemon with compose
fn production_down_project_is_idempotent() {
    let _ = contract_down_project_is_idempotent(&production_orchestrator());
}

#[test]
#[ignore] // needs Docker daemon
fn production_bollard_down_project_is_idempotent() {
    let _ = contract_down_project_is_idempotent(&production_bollard_orchestrator());
}
