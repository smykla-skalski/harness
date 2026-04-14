use super::*;

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
    with_var(super::super::backend::CONTAINER_RUNTIME_ENV, None::<&str>, || {
        assert_eq!(
            container_backend_from_env().expect("expected default backend"),
            ContainerRuntimeBackend::Bollard
        );
    });
}

#[test]
fn container_runtime_backend_accepts_docker_cli_selector() {
    with_var(
        super::super::backend::CONTAINER_RUNTIME_ENV,
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
    with_var(super::super::backend::CONTAINER_RUNTIME_ENV, Some("nope"), || {
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
        super::super::backend::CONTAINER_RUNTIME_ENV,
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
