use super::*;

fn contract_run_detached_returns_id(runtime: &dyn ContainerRuntime) {
    let config = sample_config();
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

fn contract_is_running_reflects_state(runtime: &dyn ContainerRuntime) {
    let config = sample_config();
    runtime
        .run_detached(&config)
        .expect("run_detached should succeed");
    let running = runtime
        .is_running(&config.name)
        .expect("is_running should succeed");
    assert!(running, "should be running after run_detached");
    runtime.remove(&config.name).expect("remove should succeed");
    let still = runtime
        .is_running(&config.name)
        .expect("is_running check after remove");
    assert!(!still, "should not be running after remove");
}

fn contract_remove_is_idempotent(runtime: &dyn ContainerRuntime) {
    let result = runtime.remove("nonexistent-contract-test");
    assert!(
        result.is_ok(),
        "removing nonexistent container should not fail"
    );
}

fn contract_network_lifecycle(runtime: &dyn ContainerRuntime) {
    let name = "contract-test-net";
    runtime
        .create_network(name, "172.250.0.0/24")
        .expect("create_network should succeed");
    runtime
        .remove_network(name)
        .expect("remove_network should succeed");
}

#[test]
fn fake_satisfies_run_detached_returns_id() {
    contract_run_detached_returns_id(&FakeContainerRuntime::new());
}

#[test]
fn fake_satisfies_is_running_reflects_state() {
    contract_is_running_reflects_state(&FakeContainerRuntime::new());
}

#[test]
fn fake_satisfies_remove_is_idempotent() {
    contract_remove_is_idempotent(&FakeContainerRuntime::new());
}

#[test]
fn fake_satisfies_network_lifecycle() {
    contract_network_lifecycle(&FakeContainerRuntime::new());
}
