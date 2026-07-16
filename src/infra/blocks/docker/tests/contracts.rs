use super::*;
use std::process::Command;

use crate::infra::blocks::StdProcessExecutor;

fn production_config(name: &str) -> ContainerConfig {
    ContainerConfig {
        image: "alpine:latest".to_string(),
        name: name.to_string(),
        network: "bridge".to_string(),
        env: vec![],
        ports: vec![],
        labels: vec![("contract-test".to_string(), "true".to_string())],
        entrypoint: None,
        restart_policy: None,
        extra_args: vec![],
        command: vec!["sleep".to_string(), "10".to_string()],
    }
}

fn production_runtime() -> DockerContainerRuntime {
    DockerContainerRuntime::new(Arc::new(StdProcessExecutor))
}

fn production_bollard_runtime() -> BollardContainerRuntime {
    BollardContainerRuntime::new().expect("expected Docker engine connection")
}

fn contract_run_detached_returns_id(runtime: &dyn ContainerRuntime, config: &ContainerConfig) {
    let result = runtime
        .run_detached(config)
        .expect("run_detached should succeed");
    assert_eq!(result.returncode, 0);
    assert!(
        !result.stdout.trim().is_empty(),
        "stdout should contain a container ID"
    );
    let _ = runtime.remove(&config.name);
}

fn contract_is_running_reflects_state(runtime: &dyn ContainerRuntime, config: &ContainerConfig) {
    runtime
        .run_detached(config)
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
    let result = runtime.remove("418cf829-6691-5fc0-92b1-8e5013efa2cb-contract-test");
    assert!(
        result.is_ok(),
        "removing 418cf829-6691-5fc0-92b1-8e5013efa2cb container should not fail"
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
    contract_run_detached_returns_id(&FakeContainerRuntime::new(), &sample_config());
}

#[test]
fn fake_satisfies_is_running_reflects_state() {
    contract_is_running_reflects_state(&FakeContainerRuntime::new(), &sample_config());
}

#[test]
fn fake_satisfies_remove_is_idempotent() {
    contract_remove_is_idempotent(&FakeContainerRuntime::new());
}

#[test]
fn fake_satisfies_network_lifecycle() {
    contract_network_lifecycle(&FakeContainerRuntime::new());
}

#[test]
#[ignore = "needs Docker daemon"]
fn production_cli_satisfies_run_detached_returns_id() {
    contract_run_detached_returns_id(
        &production_runtime(),
        &production_config("418cf829-6691-5fc0-92b1-8e5013efa2cb-contract-test-run"),
    );
}

#[test]
#[ignore = "needs Docker daemon"]
fn production_cli_satisfies_is_running_reflects_state() {
    contract_is_running_reflects_state(
        &production_runtime(),
        &production_config("418cf829-6691-5fc0-92b1-8e5013efa2cb-contract-test-running"),
    );
}

#[test]
#[ignore = "needs Docker daemon"]
fn production_cli_satisfies_remove_is_idempotent() {
    contract_remove_is_idempotent(&production_runtime());
}

#[test]
#[ignore = "needs Docker daemon"]
fn production_cli_satisfies_network_lifecycle() {
    contract_network_lifecycle(&production_runtime());
}

#[test]
#[ignore = "needs Docker daemon and network pull access"]
fn production_bollard_run_detached_pulls_missing_image() {
    const IMAGE: &str = "docker.io/library/busybox:1.36.1";
    const NAME: &str = "418cf829-6691-5fc0-92b1-8e5013efa2cb-contract-test-pull";

    let _ = Command::new("docker")
        .args(["image", "rm", "-f", IMAGE])
        .status();

    let runtime = production_bollard_runtime();
    let config = ContainerConfig {
        image: IMAGE.to_string(),
        name: NAME.to_string(),
        network: "bridge".to_string(),
        env: vec![],
        ports: vec![],
        labels: vec![("contract-test".to_string(), "true".to_string())],
        entrypoint: None,
        restart_policy: None,
        extra_args: vec![],
        command: vec!["sleep".to_string(), "10".to_string()],
    };

    let result = runtime
        .run_detached(&config)
        .expect("run_detached should pull the missing image");
    assert_eq!(result.returncode, 0);
    assert!(
        !result.stdout.trim().is_empty(),
        "stdout should contain a container ID"
    );

    runtime.remove(NAME).expect("remove should succeed");
}
