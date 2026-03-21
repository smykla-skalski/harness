use super::*;
use harness::infra::blocks::DockerComposeOrchestrator;

fn production_orchestrator() -> DockerComposeOrchestrator {
    use harness::infra::blocks::StdProcessExecutor;
    use std::sync::Arc;
    DockerComposeOrchestrator::new(Arc::new(StdProcessExecutor))
}

#[test]
#[ignore] // needs Docker daemon with compose
fn production_down_project_is_idempotent() {
    let _ = contract_down_project_is_idempotent(&production_orchestrator());
}
