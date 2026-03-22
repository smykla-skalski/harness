use super::*;
use harness::infra::blocks::{BollardContainerRuntime, DockerContainerRuntime};
use harness::infra::blocks::{ContainerConfig, ContainerRuntime};
use std::process::Command;

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

#[test]
#[ignore] // needs Docker daemon and network pull access
fn production_bollard_run_detached_pulls_missing_image() {
    const IMAGE: &str = "docker.io/library/busybox:1.36.1";
    const NAME: &str = "contract-test-pull";

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
