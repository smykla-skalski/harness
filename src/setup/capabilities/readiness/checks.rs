use std::env::split_paths;
use std::path::Path;

use fs_err as fs;

use crate::infra::blocks::{
    ContainerRuntimeBackend, KubernetesRuntimeBackend, container_backend_from_env,
    kubernetes_backend_from_env,
};
use crate::setup::capabilities::model::{ReadinessCheck, ReadinessCheckScope, ReadinessStatus};
use crate::setup::wrapper::choose_install_dir_with_home;
use crate::workspace::harness_data_root;

use super::CapabilityProbe;
use super::repo::{
    check_repo_is_kuma_checkout, check_repo_make_contract, check_repo_remote_publish_contract,
    check_repo_root_exists, check_repo_root_resolved, is_kuma_checkout,
};

pub(super) fn build_checks(
    project_dir: &Path,
    repo_root: Option<&Path>,
    probe: &dyn CapabilityProbe,
) -> Vec<ReadinessCheck> {
    let path_env = probe.path_env();
    let home_dir = probe.home_dir();
    let project_exists = project_dir.is_dir();
    let plugin_root = project_dir.join(".claude").join("plugins").join("suite");
    let data_root = harness_data_root();
    let backend = container_backend_from_env().unwrap_or(ContainerRuntimeBackend::Bollard);
    let kubernetes_backend =
        kubernetes_backend_from_env().unwrap_or(KubernetesRuntimeBackend::Kube);
    let docker_present = probe.command_on_path("docker");
    let kubectl_present = probe.command_on_path("kubectl");
    let repo_exists = repo_root.is_some_and(Path::is_dir);
    let repo_is_kuma = repo_root
        .filter(|path| path.is_dir())
        .is_some_and(is_kuma_checkout);

    vec![
        check_data_root_writable(&data_root),
        check_project_dir_exists(project_dir),
        check_suite_plugin_present(&plugin_root, project_exists),
        check_wrapper_install_target(&path_env, &home_dir),
        check_binary_present(
            "docker_binary_present",
            "Docker CLI is available.",
            "Docker CLI is missing.",
            "Install Docker Desktop or another Docker-compatible runtime and ensure `docker` is on PATH.",
            "docker",
            probe,
        ),
        check_docker_running(docker_present, backend, probe),
        check_binary_present(
            "make_binary_present",
            "`make` is available.",
            "`make` is missing.",
            "Install `make` and ensure it is on PATH.",
            "make",
            probe,
        ),
        check_binary_present(
            "k3d_binary_present",
            "k3d is available.",
            "k3d is missing.",
            "Install `k3d` and ensure it is on PATH for Kubernetes profile setup.",
            "k3d",
            probe,
        ),
        check_binary_present(
            "kubectl_binary_present",
            "kubectl is available.",
            "kubectl is missing.",
            "Install `kubectl` and ensure it is on PATH for Kubernetes profile setup.",
            "kubectl",
            probe,
        ),
        check_kubernetes_runtime_ready(kubectl_present, kubernetes_backend),
        check_binary_present(
            "helm_binary_present",
            "Helm is available.",
            "Helm is missing.",
            "Install `helm` and ensure it is on PATH for Kubernetes profile setup.",
            "helm",
            probe,
        ),
        check_docker_compose_available(docker_present, backend, probe),
        check_repo_root_resolved(repo_root),
        check_repo_root_exists(repo_root),
        check_repo_is_kuma_checkout(repo_root, repo_exists),
        check_repo_make_contract(repo_root, repo_is_kuma),
        check_repo_remote_publish_contract(repo_root, repo_is_kuma),
    ]
}

fn check_data_root_writable(path: &Path) -> ReadinessCheck {
    let probe_path = path.join(".capabilities-write-check");
    let result = fs::create_dir_all(path)
        .and_then(|()| {
            fs::OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(&probe_path)
        })
        .map(|_| ());
    let _ = fs::remove_file(&probe_path);

    match result {
        Ok(()) => pass(
            "data_root_writable",
            ReadinessCheckScope::Machine,
            "Harness data root is writable.",
            Some(path),
            None,
        ),
        Err(error) => fail(
            "data_root_writable",
            ReadinessCheckScope::Machine,
            format!("Harness data root is not writable: {error}"),
            Some(path),
            Some("Set XDG_DATA_HOME to a writable location before using harness."),
        ),
    }
}

fn check_project_dir_exists(project_dir: &Path) -> ReadinessCheck {
    if project_dir.is_dir() {
        pass(
            "project_dir_exists",
            ReadinessCheckScope::Project,
            "Project directory exists.",
            Some(project_dir),
            None,
        )
    } else {
        fail(
            "project_dir_exists",
            ReadinessCheckScope::Project,
            "Project directory is missing.",
            Some(project_dir),
            Some("Run the command from a project checkout or pass `--project-dir`."),
        )
    }
}

fn check_suite_plugin_present(plugin_root: &Path, project_exists: bool) -> ReadinessCheck {
    if !project_exists {
        return skipped(
            "suite_plugin_present",
            ReadinessCheckScope::Project,
            "Suite plugin check skipped because the project directory is missing.",
            Some(plugin_root),
            Some("Resolve the project directory first, then bootstrap the project wrapper."),
        );
    }

    if plugin_root.is_dir() {
        pass(
            "suite_plugin_present",
            ReadinessCheckScope::Project,
            "Project suite plugin root is present.",
            Some(plugin_root),
            None,
        )
    } else {
        fail(
            "suite_plugin_present",
            ReadinessCheckScope::Project,
            "Project suite plugin root is missing.",
            Some(plugin_root),
            Some("Run project bootstrap so `.claude/plugins/suite` exists in the active project."),
        )
    }
}

fn check_wrapper_install_target(path_env: &str, home_dir: &Path) -> ReadinessCheck {
    match choose_install_dir_with_home(path_env, home_dir) {
        Ok((target, _)) => pass(
            "wrapper_install_target_available",
            ReadinessCheckScope::Project,
            "Harness wrapper install target is available.",
            Some(&target),
            None,
        ),
        Err(error) => fail(
            "wrapper_install_target_available",
            ReadinessCheckScope::Project,
            format!("Harness wrapper install target is unavailable: {error}"),
            None,
            Some("Add a writable user bin directory such as `~/.local/bin` to PATH."),
        ),
    }
}

fn check_binary_present(
    code: &str,
    success: &str,
    failure: &str,
    hint: &str,
    command: &str,
    probe: &dyn CapabilityProbe,
) -> ReadinessCheck {
    if probe.command_on_path(command) {
        pass(code, ReadinessCheckScope::Machine, success, None, None)
    } else {
        fail(
            code,
            ReadinessCheckScope::Machine,
            failure,
            None,
            Some(hint),
        )
    }
}

fn check_kubernetes_runtime_ready(
    kubectl_present: bool,
    backend: KubernetesRuntimeBackend,
) -> ReadinessCheck {
    match backend {
        KubernetesRuntimeBackend::Kube => pass(
            "kubernetes_runtime_ready",
            ReadinessCheckScope::Machine,
            "Native Kubernetes runtime is available.",
            None,
            None,
        ),
        KubernetesRuntimeBackend::KubectlCli if kubectl_present => pass(
            "kubernetes_runtime_ready",
            ReadinessCheckScope::Machine,
            "kubectl-backed Kubernetes runtime is available.",
            None,
            None,
        ),
        KubernetesRuntimeBackend::KubectlCli => fail(
            "kubernetes_runtime_ready",
            ReadinessCheckScope::Machine,
            "kubectl-backed Kubernetes runtime is unavailable because kubectl is missing.",
            None,
            Some("Install `kubectl` or switch HARNESS_KUBERNETES_RUNTIME to `kube`."),
        ),
    }
}

fn check_docker_running(
    docker_present: bool,
    backend: ContainerRuntimeBackend,
    probe: &dyn CapabilityProbe,
) -> ReadinessCheck {
    if backend == ContainerRuntimeBackend::DockerCli && !docker_present {
        return skipped(
            "docker_running",
            ReadinessCheckScope::Machine,
            "Docker daemon check skipped because the Docker CLI is missing.",
            None,
            Some("Install Docker first, then rerun capabilities."),
        );
    }

    let daemon_ready = match backend {
        ContainerRuntimeBackend::DockerCli => probe.run_command_success("docker", &["info"]),
        ContainerRuntimeBackend::Bollard => probe.docker_engine_reachable(),
    };

    if daemon_ready {
        pass(
            "docker_running",
            ReadinessCheckScope::Machine,
            "Docker daemon is reachable.",
            None,
            None,
        )
    } else {
        fail(
            "docker_running",
            ReadinessCheckScope::Machine,
            "Docker daemon is not reachable.",
            None,
            Some("Start Docker Desktop or the local Docker daemon."),
        )
    }
}

fn check_docker_compose_available(
    docker_present: bool,
    backend: ContainerRuntimeBackend,
    probe: &dyn CapabilityProbe,
) -> ReadinessCheck {
    if backend == ContainerRuntimeBackend::DockerCli && !docker_present {
        return skipped(
            "docker_compose_available",
            ReadinessCheckScope::Machine,
            "Docker Compose check skipped because the Docker CLI is missing.",
            None,
            Some("Install Docker first, then rerun capabilities."),
        );
    }

    let compose_ready = match backend {
        ContainerRuntimeBackend::DockerCli => {
            probe.run_command_success("docker", &["compose", "version"])
        }
        ContainerRuntimeBackend::Bollard => probe.docker_engine_reachable(),
    };

    if compose_ready {
        pass(
            "docker_compose_available",
            ReadinessCheckScope::Machine,
            match backend {
                ContainerRuntimeBackend::DockerCli => "Docker Compose is available.",
                ContainerRuntimeBackend::Bollard => {
                    "Harness compose runtime is available through the Docker Engine API."
                }
            },
            None,
            None,
        )
    } else {
        fail(
            "docker_compose_available",
            ReadinessCheckScope::Machine,
            match backend {
                ContainerRuntimeBackend::DockerCli => "Docker Compose is unavailable.",
                ContainerRuntimeBackend::Bollard => {
                    "Harness compose runtime cannot reach the Docker Engine API."
                }
            },
            None,
            Some(match backend {
                ContainerRuntimeBackend::DockerCli => {
                    "Install Docker Compose support for universal profile setup."
                }
                ContainerRuntimeBackend::Bollard => {
                    "Start Docker Desktop or the local Docker daemon."
                }
            }),
        )
    }
}

pub(super) fn pass(
    code: &str,
    scope: ReadinessCheckScope,
    summary: impl Into<String>,
    path: Option<&Path>,
    hint: Option<&str>,
) -> ReadinessCheck {
    check(
        code,
        scope,
        ReadinessStatus::Pass,
        summary,
        path,
        hint.map(str::to_string),
    )
}

pub(super) fn fail(
    code: &str,
    scope: ReadinessCheckScope,
    summary: impl Into<String>,
    path: Option<&Path>,
    hint: Option<&str>,
) -> ReadinessCheck {
    check(
        code,
        scope,
        ReadinessStatus::Fail,
        summary,
        path,
        hint.map(str::to_string),
    )
}

pub(super) fn skipped(
    code: &str,
    scope: ReadinessCheckScope,
    summary: impl Into<String>,
    path: Option<&Path>,
    hint: Option<&str>,
) -> ReadinessCheck {
    check(
        code,
        scope,
        ReadinessStatus::Skipped,
        summary,
        path,
        hint.map(str::to_string),
    )
}

fn check(
    code: &str,
    scope: ReadinessCheckScope,
    status: ReadinessStatus,
    summary: impl Into<String>,
    path: Option<&Path>,
    hint: Option<String>,
) -> ReadinessCheck {
    ReadinessCheck {
        code: code.to_string(),
        scope,
        status,
        summary: summary.into(),
        path: path.map(|item| item.display().to_string()),
        hint,
    }
}

pub(super) fn command_on_path(command: &str, path_env: &str) -> bool {
    let candidate = Path::new(command);
    if candidate.components().count() > 1 {
        return candidate.is_file();
    }

    split_paths(path_env)
        .map(|dir| dir.join(command))
        .any(|path| path.is_file())
}
