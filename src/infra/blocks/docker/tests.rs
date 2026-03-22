use std::sync::Arc;

use super::*;
use crate::infra::blocks::{
    FakeContainerRuntime, FakeInvocation, FakeProcessExecutor, FakeProcessMethod, FakeResponse,
};
use temp_env::with_var;

fn success_result(args: &[&str], stdout: &str) -> CommandResult {
    CommandResult {
        args: args.iter().map(|arg| (*arg).to_string()).collect(),
        returncode: 0,
        stdout: stdout.to_string(),
        stderr: String::new(),
    }
}

fn sample_config() -> ContainerConfig {
    ContainerConfig {
        image: "example:latest".to_string(),
        name: "example".to_string(),
        network: "mesh-net".to_string(),
        env: vec![("MODE".to_string(), "test".to_string())],
        ports: vec![ContainerPort::fixed(8080, 80)],
        labels: vec![("suite".to_string(), "mesh".to_string())],
        entrypoint: None,
        restart_policy: Some("unless-stopped".to_string()),
        extra_args: vec![],
        command: vec!["server".to_string()],
    }
}

fn last_invocation(fake: &FakeProcessExecutor) -> FakeInvocation {
    fake.invocations()
        .into_iter()
        .last()
        .expect("expected at least one invocation")
}

#[test]
fn docker_container_runtime_run_detached_builds_expected_command() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "docker".to_string(),
        expected_args: Some(vec![
            "docker".into(),
            "run".into(),
            "-d".into(),
            "--name".into(),
            "example".into(),
            "--network".into(),
            "mesh-net".into(),
            "-e".into(),
            "MODE=test".into(),
            "-p".into(),
            "8080:80".into(),
            "--label".into(),
            "suite=mesh".into(),
            "--restart".into(),
            "unless-stopped".into(),
            "example:latest".into(),
            "server".into(),
        ]),
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(
            &[
                "docker",
                "run",
                "-d",
                "--name",
                "example",
                "--network",
                "mesh-net",
                "-e",
                "MODE=test",
                "-p",
                "8080:80",
                "--label",
                "suite=mesh",
                "--restart",
                "unless-stopped",
                "example:latest",
                "server",
            ],
            "container-id\n",
        )),
    }]));
    let runtime = DockerContainerRuntime::new(fake);

    let result = runtime
        .run_detached(&sample_config())
        .expect("expected docker run to succeed");

    assert_eq!(result.stdout, "container-id\n");
}

#[test]
fn docker_container_runtime_run_detached_supports_ephemeral_host_ports() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "docker".to_string(),
        expected_args: Some(vec![
            "docker".into(),
            "run".into(),
            "-d".into(),
            "--name".into(),
            "example".into(),
            "--network".into(),
            "mesh-net".into(),
            "-e".into(),
            "MODE=test".into(),
            "-p".into(),
            "9902".into(),
            "--label".into(),
            "suite=mesh".into(),
            "--restart".into(),
            "unless-stopped".into(),
            "example:latest".into(),
            "server".into(),
        ]),
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(
            &[
                "docker",
                "run",
                "-d",
                "--name",
                "example",
                "--network",
                "mesh-net",
                "-e",
                "MODE=test",
                "-p",
                "9902",
                "--label",
                "suite=mesh",
                "--restart",
                "unless-stopped",
                "example:latest",
                "server",
            ],
            "container-id\n",
        )),
    }]));
    let runtime = DockerContainerRuntime::new(fake);
    let mut config = sample_config();
    config.ports = vec![ContainerPort::ephemeral(9902)];

    let result = runtime
        .run_detached(&config)
        .expect("expected docker run to succeed");

    assert_eq!(result.stdout, "container-id\n");
}

#[test]
fn docker_container_runtime_remove_invokes_rm_force() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "rm".into(),
                "-f".into(),
                "example".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(&["docker", "rm", "-f", "example"], "")),
        },
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "inspect".into(),
                "-f".into(),
                "{{.Id}}".into(),
                "example".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(CommandResult {
                args: vec![
                    "docker".into(),
                    "inspect".into(),
                    "-f".into(),
                    "{{.Id}}".into(),
                    "example".into(),
                ],
                returncode: 1,
                stdout: String::new(),
                stderr: "Error: No such container: example".to_string(),
            }),
        },
    ]));
    let runtime = DockerContainerRuntime::new(fake);

    let result = runtime
        .remove("example")
        .expect("expected remove to succeed");

    assert_eq!(result.returncode, 0);
}

#[test]
fn docker_container_runtime_remove_waits_for_removal_in_progress() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "rm".into(),
                "-f".into(),
                "example".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(CommandResult {
                args: vec!["docker".into(), "rm".into(), "-f".into(), "example".into()],
                returncode: 1,
                stdout: String::new(),
                stderr: "removal of container example is already in progress".to_string(),
            }),
        },
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "inspect".into(),
                "-f".into(),
                "{{.Id}}".into(),
                "example".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &["docker", "inspect", "-f", "{{.Id}}", "example"],
                "container-id\n",
            )),
        },
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "inspect".into(),
                "-f".into(),
                "{{.Id}}".into(),
                "example".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(CommandResult {
                args: vec![
                    "docker".into(),
                    "inspect".into(),
                    "-f".into(),
                    "{{.Id}}".into(),
                    "example".into(),
                ],
                returncode: 1,
                stdout: String::new(),
                stderr: "Error: No such container: example".to_string(),
            }),
        },
    ]));
    let runtime = DockerContainerRuntime::new(fake);

    let result = runtime
        .remove("example")
        .expect("expected remove to succeed");

    assert_eq!(result.returncode, 1);
}

#[test]
fn docker_container_runtime_inspect_ip_handles_present_and_missing_ips() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: None,
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &["docker", "inspect", "-f", "{{...}}", "example"],
                "10.0.0.5\n",
            )),
        },
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: None,
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &["docker", "inspect", "-f", "{{...}}", "example"],
                "\n",
            )),
        },
    ]));
    let runtime = DockerContainerRuntime::new(fake);

    let ip = runtime
        .inspect_ip("example", "mesh-net")
        .expect("expected IP lookup to succeed");
    assert_eq!(ip, "10.0.0.5");

    let error = runtime
        .inspect_ip("example", "mesh-net")
        .expect_err("expected empty IP to fail");
    assert!(error.to_string().contains("no IP on network mesh-net"));
}

#[test]
fn docker_container_runtime_is_running_reflects_inspect_output() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "inspect".into(),
                "-f".into(),
                "{{.State.Running}}".into(),
                "example".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &["docker", "inspect", "-f", "{{.State.Running}}", "example"],
                "true\n",
            )),
        },
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "inspect".into(),
                "-f".into(),
                "{{.State.Running}}".into(),
                "example".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(CommandResult {
                args: vec![
                    "docker".into(),
                    "inspect".into(),
                    "-f".into(),
                    "{{.State.Running}}".into(),
                    "example".into(),
                ],
                returncode: 1,
                stdout: "false\n".to_string(),
                stderr: String::new(),
            }),
        },
    ]));
    let runtime = DockerContainerRuntime::new(fake);

    assert!(
        runtime
            .is_running("example")
            .expect("expected inspect to succeed")
    );
    assert!(
        !runtime
            .is_running("example")
            .expect("expected inspect to succeed")
    );
}

#[test]
fn docker_container_runtime_inspect_host_port_parses_docker_port_output() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "docker".to_string(),
        expected_args: Some(vec![
            "docker".into(),
            "port".into(),
            "example".into(),
            "9902/tcp".into(),
        ]),
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(
            &["docker", "port", "example", "9902/tcp"],
            "0.0.0.0:31234\n",
        )),
    }]));
    let runtime = DockerContainerRuntime::new(fake);

    let port = runtime
        .inspect_host_port("example", 9902)
        .expect("expected host port lookup");

    assert_eq!(port, 31_234);
}

#[test]
fn docker_container_runtime_exec_command_builds_expected_args() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "docker".to_string(),
        expected_args: Some(vec![
            "docker".into(),
            "exec".into(),
            "example".into(),
            "echo".into(),
            "hello".into(),
        ]),
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(
            &["docker", "exec", "example", "echo", "hello"],
            "hello\n",
        )),
    }]));
    let runtime = DockerContainerRuntime::new(fake);

    let result = runtime
        .exec_command("example", &["echo", "hello"])
        .expect("expected exec to succeed");

    assert_eq!(result.stdout, "hello\n");
}

#[test]
fn docker_container_runtime_list_formatted_uses_ps_without_all_flag() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "docker".to_string(),
        expected_args: Some(vec![
            "docker".into(),
            "ps".into(),
            "--filter".into(),
            "label=suite=mesh".into(),
            "--format".into(),
            "{{.Names}}".into(),
        ]),
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(
            &[
                "docker",
                "ps",
                "--filter",
                "label=suite=mesh",
                "--format",
                "{{.Names}}",
            ],
            "svc-1\n",
        )),
    }]));
    let runtime = DockerContainerRuntime::new(fake);

    let result = runtime
        .list_formatted(&["--filter", "label=suite=mesh"], "{{.Names}}")
        .expect("expected list_formatted to succeed");

    assert_eq!(result.stdout, "svc-1\n");
}

#[test]
fn docker_container_runtime_write_file_invokes_docker_cp() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "docker".to_string(),
        expected_args: None,
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(&["docker", "cp"], "")),
    }]));
    let runtime = DockerContainerRuntime::new(fake.clone());

    runtime
        .write_file("example", "/tmp/config.yaml", "kind: ConfigMap")
        .expect("expected write_file to succeed");

    let invocation = last_invocation(fake.as_ref());
    assert_eq!(invocation.method, FakeProcessMethod::Run);
    assert_eq!(invocation.args[0], "docker");
    assert_eq!(invocation.args[1], "cp");
    assert_eq!(invocation.args[3], "example:/tmp/config.yaml");
    assert!(!invocation.args[2].is_empty());
}

#[test]
fn docker_container_runtime_create_network_skips_create_when_network_exists() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "docker".to_string(),
        expected_args: Some(vec![
            "docker".into(),
            "network".into(),
            "ls".into(),
            "--filter".into(),
            "name=^mesh-net$".into(),
            "--format".into(),
            "{{.Name}}".into(),
        ]),
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(
            &[
                "docker",
                "network",
                "ls",
                "--filter",
                "name=^mesh-net$",
                "--format",
                "{{.Name}}",
            ],
            "mesh-net\n",
        )),
    }]));
    let runtime = DockerContainerRuntime::new(fake.clone());

    runtime
        .create_network("mesh-net", "172.18.0.0/24")
        .expect("expected create_network to succeed");

    assert_eq!(fake.invocations().len(), 1);
}

#[test]
fn docker_container_runtime_remove_by_label_removes_each_match() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "ps".into(),
                "-a".into(),
                "--filter".into(),
                "label=suite=mesh".into(),
                "--format".into(),
                "{{.Names}}".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &[
                    "docker",
                    "ps",
                    "-a",
                    "--filter",
                    "label=suite=mesh",
                    "--format",
                    "{{.Names}}",
                ],
                "cp-1\ndp-1\n",
            )),
        },
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "rm".into(),
                "-f".into(),
                "cp-1".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(&["docker", "rm", "-f", "cp-1"], "")),
        },
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "inspect".into(),
                "-f".into(),
                "{{.Id}}".into(),
                "cp-1".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(CommandResult {
                args: vec![
                    "docker".into(),
                    "inspect".into(),
                    "-f".into(),
                    "{{.Id}}".into(),
                    "cp-1".into(),
                ],
                returncode: 1,
                stdout: String::new(),
                stderr: "Error: No such container: cp-1".to_string(),
            }),
        },
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "rm".into(),
                "-f".into(),
                "dp-1".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(&["docker", "rm", "-f", "dp-1"], "")),
        },
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "inspect".into(),
                "-f".into(),
                "{{.Id}}".into(),
                "dp-1".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(CommandResult {
                args: vec![
                    "docker".into(),
                    "inspect".into(),
                    "-f".into(),
                    "{{.Id}}".into(),
                    "dp-1".into(),
                ],
                returncode: 1,
                stdout: String::new(),
                stderr: "Error: No such container: dp-1".to_string(),
            }),
        },
    ]));
    let runtime = DockerContainerRuntime::new(fake);

    let removed = runtime
        .remove_by_label("suite=mesh")
        .expect("expected remove_by_label to succeed");

    assert_eq!(removed, vec!["cp-1", "dp-1"]);
}

#[test]
fn fake_container_runtime_tracks_container_lifecycle() {
    let runtime = FakeContainerRuntime::new();
    let config = sample_config();

    runtime
        .create_network("mesh-net", "172.18.0.0/24")
        .expect("expected network creation to succeed");
    runtime
        .run_detached(&config)
        .expect("expected run_detached to succeed");
    assert!(
        runtime
            .is_running("example")
            .expect("expected running check to succeed")
    );
    assert_eq!(
        runtime
            .inspect_ip("example", "mesh-net")
            .expect("expected IP lookup to succeed"),
        "172.18.0.2"
    );
    runtime
        .write_file("example", "/tmp/config.yaml", "data")
        .expect("expected write_file to succeed");

    let removed = runtime
        .remove_by_label("suite=mesh")
        .expect("expected remove_by_label to succeed");
    assert_eq!(removed, vec!["example"]);
    assert!(
        !runtime
            .is_running("example")
            .expect("expected running check to succeed")
    );
}

#[test]
fn docker_types_are_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}

    assert_send_sync::<BollardContainerRuntime>();
    assert_send_sync::<DockerContainerRuntime>();
    assert_send_sync::<FakeContainerRuntime>();
}

#[test]
fn container_runtime_backend_defaults_to_bollard() {
    with_var(super::backend::CONTAINER_RUNTIME_ENV, None::<&str>, || {
        assert_eq!(
            container_backend_from_env().expect("expected default backend"),
            ContainerRuntimeBackend::Bollard
        );
    });
}

#[test]
fn container_runtime_backend_accepts_docker_cli_selector() {
    with_var(
        super::backend::CONTAINER_RUNTIME_ENV,
        Some("docker-cli"),
        || {
            assert_eq!(
                container_backend_from_env().expect("expected docker-cli backend"),
                ContainerRuntimeBackend::DockerCli
            );
        },
    );
}

#[test]
fn container_runtime_backend_rejects_invalid_selector() {
    with_var(super::backend::CONTAINER_RUNTIME_ENV, Some("nope"), || {
        let error = container_backend_from_env().expect_err("expected invalid selector to fail");
        assert!(
            error
                .to_string()
                .contains("expected `bollard` or `docker-cli`"),
            "unexpected error: {error}"
        );
    });
}

#[test]
fn container_backends_from_env_builds_cli_runtime_and_compose_pair() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "ps".into(),
                "--format".into(),
                "{{.Names}}".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &["docker", "ps", "--format", "{{.Names}}"],
                "svc-1\n",
            )),
        },
        FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "compose".into(),
                "-p".into(),
                "mesh".into(),
                "down".into(),
                "-v".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &["docker", "compose", "-p", "mesh", "down", "-v"],
                "",
            )),
        },
    ]));

    with_var(
        super::backend::CONTAINER_RUNTIME_ENV,
        Some("docker-cli"),
        || {
            let selected = container_backends_from_env(fake.clone()).expect("expected backends");
            assert_eq!(selected.backend, ContainerRuntimeBackend::DockerCli);

            let listed = selected
                .container_runtime
                .list_formatted(&[], "{{.Names}}")
                .expect("expected docker ps");
            assert_eq!(listed.stdout, "svc-1\n");

            let down = selected
                .compose_orchestrator
                .down_project("mesh")
                .expect("expected docker compose down");
            assert_eq!(down.returncode, 0);
        },
    );
}

// -- Contract tests: fake satisfies the same invariants as production --

mod contracts {
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
}
