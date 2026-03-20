use std::path::Path;
use std::sync::Arc;

use super::*;
use crate::infra::blocks::{
    FakeComposeOrchestrator, FakeProcessExecutor, FakeProcessMethod, FakeResponse,
};

fn success_result(args: &[&str]) -> CommandResult {
    CommandResult {
        args: args.iter().map(|arg| (*arg).to_string()).collect(),
        returncode: 0,
        stdout: String::new(),
        stderr: String::new(),
    }
}

fn sample_topology_with_service() -> ComposeTopology {
    ComposeTopology {
        project_name: "mesh".to_string(),
        network: NetworkSpec {
            name: "mesh-net".to_string(),
            subnet: "172.57.0.0/16".to_string(),
        },
        services: vec![ServiceSpec {
            name: "cp".to_string(),
            image: "kumahq/kuma-cp:latest".to_string(),
            environment: BTreeMap::from([("KUMA_MODE".to_string(), "zone".to_string())]),
            ports: vec![(5681, 5681), (5678, 5678)],
            command: vec!["run".to_string()],
            entrypoint: None,
            depends_on: vec![],
            healthcheck: Some(HealthcheckSpec {
                test: vec!["CMD".to_string(), "true".to_string()],
                interval_seconds: Some(5),
                timeout_seconds: Some(5),
                retries: Some(10),
                start_period_seconds: Some(5),
            }),
            restart: Some("unless-stopped".to_string()),
        }],
    }
}

#[test]
fn compose_topology_renders_compose_yaml() {
    let yaml = sample_topology_with_service()
        .to_yaml()
        .expect("expected compose yaml");

    for expected in [
        "services:",
        "cp:",
        "kumahq/kuma-cp:latest",
        "mesh-net",
        "172.57.0.0/16",
        "5681:5681",
        "start_period: '5s'",
    ] {
        assert!(yaml.contains(expected), "missing: {expected}");
    }
}

#[test]
fn compose_dependencies_render_simple_list_when_unconditional() {
    let topology = ComposeTopology {
        project_name: "mesh".to_string(),
        network: NetworkSpec {
            name: "mesh-net".to_string(),
            subnet: "172.57.0.0/16".to_string(),
        },
        services: vec![ServiceSpec {
            name: "zone".to_string(),
            image: "img".to_string(),
            environment: BTreeMap::new(),
            ports: vec![],
            command: vec![],
            entrypoint: None,
            depends_on: vec![ServiceDependency {
                service_name: "global".to_string(),
                condition: None,
            }],
            healthcheck: None,
            restart: None,
        }],
    };

    let yaml = topology.to_yaml().expect("expected compose yaml");

    assert!(yaml.contains("depends_on:"));
    assert!(yaml.contains("- global"));
}

#[test]
fn compose_dependencies_render_conditional_map_when_needed() {
    let topology = ComposeTopology {
        project_name: "mesh".to_string(),
        network: NetworkSpec {
            name: "mesh-net".to_string(),
            subnet: "172.57.0.0/16".to_string(),
        },
        services: vec![ServiceSpec {
            name: "zone".to_string(),
            image: "img".to_string(),
            environment: BTreeMap::new(),
            ports: vec![],
            command: vec![],
            entrypoint: None,
            depends_on: vec![ServiceDependency {
                service_name: "postgres".to_string(),
                condition: Some("service_healthy".to_string()),
            }],
            healthcheck: None,
            restart: None,
        }],
    };

    let yaml = topology.to_yaml().expect("expected compose yaml");

    assert!(yaml.contains("postgres:"));
    assert!(yaml.contains("condition: service_healthy"));
}

#[test]
fn compose_file_writes_to_disk() {
    let topology = ComposeTopology {
        project_name: "mesh".to_string(),
        network: NetworkSpec {
            name: "mesh-net".to_string(),
            subnet: "172.57.0.0/16".to_string(),
        },
        services: vec![],
    };

    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("docker-compose.yaml");

    topology
        .to_compose_file()
        .write_to(&path)
        .expect("expected compose file write");

    let content = fs::read_to_string(&path).expect("read compose file");
    assert!(content.contains("networks:"));
    assert!(content.contains("mesh-net"));
}

#[test]
fn docker_compose_orchestrator_up_uses_streaming_compose_command() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "docker".to_string(),
        expected_args: Some(vec![
            "docker".into(),
            "compose".into(),
            "-f".into(),
            "/tmp/compose.yml".into(),
            "-p".into(),
            "mesh".into(),
            "up".into(),
            "-d".into(),
            "--wait".into(),
            "--wait-timeout".into(),
            "90".into(),
        ]),
        expected_method: Some(FakeProcessMethod::RunStreaming),
        result: Ok(success_result(&[
            "docker",
            "compose",
            "-f",
            "/tmp/compose.yml",
            "-p",
            "mesh",
            "up",
            "-d",
            "--wait",
            "--wait-timeout",
            "90",
        ])),
    }]));
    let orchestrator = DockerComposeOrchestrator::new(fake);

    let result = orchestrator
        .up(
            Path::new("/tmp/compose.yml"),
            "mesh",
            Duration::from_secs(90),
        )
        .expect("expected compose up to succeed");

    assert_eq!(result.returncode, 0);
}

#[test]
fn docker_compose_orchestrator_down_includes_volume_removal() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "docker".to_string(),
        expected_args: Some(vec![
            "docker".into(),
            "compose".into(),
            "-f".into(),
            "/tmp/compose.yml".into(),
            "-p".into(),
            "mesh".into(),
            "down".into(),
            "-v".into(),
        ]),
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(&[
            "docker",
            "compose",
            "-f",
            "/tmp/compose.yml",
            "-p",
            "mesh",
            "down",
            "-v",
        ])),
    }]));
    let orchestrator = DockerComposeOrchestrator::new(fake);

    let result = orchestrator
        .down(Path::new("/tmp/compose.yml"), "mesh")
        .expect("expected compose down to succeed");

    assert_eq!(result.returncode, 0);
}

#[test]
fn docker_compose_orchestrator_down_project_works_without_file() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
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
        result: Ok(success_result(&[
            "docker", "compose", "-p", "mesh", "down", "-v",
        ])),
    }]));
    let orchestrator = DockerComposeOrchestrator::new(fake);

    let result = orchestrator
        .down_project("mesh")
        .expect("expected compose down to succeed");

    assert_eq!(result.returncode, 0);
}

#[test]
fn fake_compose_orchestrator_tracks_project_state() {
    let orchestrator = FakeComposeOrchestrator::new();

    orchestrator
        .up(
            Path::new("/tmp/compose.yml"),
            "mesh",
            Duration::from_secs(60),
        )
        .expect("expected fake up to succeed");
    assert!(
        orchestrator
            .projects
            .lock()
            .expect("lock poisoned")
            .contains_key("mesh")
    );

    orchestrator
        .down_project("mesh")
        .expect("expected fake down to succeed");
    assert!(
        !orchestrator
            .projects
            .lock()
            .expect("lock poisoned")
            .contains_key("mesh")
    );
}

#[test]
fn compose_types_are_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}

    assert_send_sync::<ComposeFile>();
    assert_send_sync::<ComposeTopology>();
    assert_send_sync::<DockerComposeOrchestrator>();
    assert_send_sync::<FakeComposeOrchestrator>();
}

// -- Contract tests: fake satisfies the same invariants as production --

mod contracts {
    use super::*;

    fn contract_up_then_down_succeeds(
        orchestrator: &dyn ComposeOrchestrator,
        compose_file: &Path,
        project_name: &str,
    ) {
        let up_result = orchestrator
            .up(compose_file, project_name, Duration::from_secs(60))
            .expect("compose up should succeed");
        assert_eq!(up_result.returncode, 0);
        let down_result = orchestrator
            .down(compose_file, project_name)
            .expect("compose down should succeed");
        assert_eq!(down_result.returncode, 0);
    }

    fn contract_down_project_is_idempotent(orchestrator: &dyn ComposeOrchestrator) {
        let result = orchestrator.down_project("nonexistent-contract-test-project");
        assert!(
            result.is_ok(),
            "down_project on missing project should not fail"
        );
    }

    #[test]
    fn fake_satisfies_up_then_down() {
        contract_up_then_down_succeeds(
            &FakeComposeOrchestrator::new(),
            Path::new("/tmp/compose.yml"),
            "contract-test",
        );
    }

    #[test]
    fn fake_satisfies_down_project_is_idempotent() {
        contract_down_project_is_idempotent(&FakeComposeOrchestrator::new());
    }
}
