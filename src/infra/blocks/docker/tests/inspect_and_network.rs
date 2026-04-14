use super::*;

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
