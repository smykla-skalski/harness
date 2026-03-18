use harness::blocks::{ContainerConfig, ContainerRuntime};

/// Helper to build a minimal container config for contract tests.
#[must_use]
pub fn sample_container_config() -> ContainerConfig {
    ContainerConfig {
        image: "alpine:latest".to_string(),
        name: "contract-test".to_string(),
        network: "bridge".to_string(),
        env: vec![],
        ports: vec![],
        labels: vec![("contract-test".to_string(), "true".to_string())],
        extra_args: vec![],
        command: vec!["sleep".to_string(), "10".to_string()],
    }
}

/// `run_detached` starts a container and returns a non-empty container ID.
///
/// # Panics
/// Panics if the runtime fails to start or inspect the container.
pub fn contract_run_detached_returns_id(runtime: &dyn ContainerRuntime) {
    let config = sample_container_config();
    let result = runtime
        .run_detached(&config)
        .expect("run_detached should succeed");
    assert_eq!(result.returncode, 0);
    assert!(
        !result.stdout.trim().is_empty(),
        "stdout should contain a container ID"
    );
    let _ = runtime.remove(&config.name);
}

/// `is_running` returns true for a running container.
///
/// # Panics
/// Panics if the runtime fails at any lifecycle step.
pub fn contract_is_running_reflects_state(runtime: &dyn ContainerRuntime) {
    let config = sample_container_config();
    runtime
        .run_detached(&config)
        .expect("run_detached should succeed");

    let running = runtime
        .is_running(&config.name)
        .expect("is_running should succeed");
    assert!(running, "container should be running after run_detached");

    runtime
        .remove(&config.name)
        .expect("remove should succeed");

    let still_running = runtime
        .is_running(&config.name)
        .expect("is_running should succeed after remove");
    assert!(!still_running, "container should not be running after remove");
}

/// `remove` succeeds for both existing and non-existing containers.
///
/// # Panics
/// Panics if removing a nonexistent container returns an error.
pub fn contract_remove_is_idempotent(runtime: &dyn ContainerRuntime) {
    let result = runtime.remove("nonexistent-contract-test");
    assert!(
        result.is_ok(),
        "removing a nonexistent container should not fail"
    );
}

/// `create_network` and `remove_network` succeed in sequence.
///
/// # Panics
/// Panics if network creation or removal fails.
pub fn contract_network_lifecycle(runtime: &dyn ContainerRuntime) {
    let name = "contract-test-net";
    runtime
        .create_network(name, "172.250.0.0/24")
        .expect("create_network should succeed");
    runtime
        .remove_network(name)
        .expect("remove_network should succeed");
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness::blocks::DockerContainerRuntime;

    fn production_runtime() -> DockerContainerRuntime {
        use harness::blocks::StdProcessExecutor;
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
}
