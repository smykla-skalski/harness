use super::*;

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
