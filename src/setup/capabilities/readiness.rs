use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use fs_err as fs;

use crate::kernel::topology::{ClusterProvider, Platform};
use crate::setup::wrapper::choose_install_dir_with_home;
use crate::workspace::{dirs_home, harness_data_root};

use super::model::{
    Feature, FeatureInfo, PlatformReadiness, ProfileReadiness, ReadinessCheck, ReadinessCheckScope,
    ReadinessReport, ReadinessScope, ReadinessStatus, ReadinessSummary, TopologyMode,
};

pub(super) trait CapabilityProbe {
    fn path_env(&self) -> String;
    fn home_dir(&self) -> PathBuf;
    fn command_on_path(&self, command: &str) -> bool;
    fn run_command_success(&self, program: &str, args: &[&str]) -> bool;
}

#[derive(Debug, Clone, Copy)]
pub(super) struct SystemProbe;

impl CapabilityProbe for SystemProbe {
    fn path_env(&self) -> String {
        env::var("PATH").unwrap_or_default()
    }

    fn home_dir(&self) -> PathBuf {
        dirs_home()
    }

    fn command_on_path(&self, command: &str) -> bool {
        command_on_path(command, &self.path_env())
    }

    fn run_command_success(&self, program: &str, args: &[&str]) -> bool {
        Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    }
}

pub(super) fn evaluate(
    raw_project_dir: Option<&str>,
    raw_repo_root: Option<&str>,
    feature_map: &BTreeMap<Feature, FeatureInfo>,
    probe: &dyn CapabilityProbe,
) -> ReadinessReport {
    let cwd = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let project_dir = resolve_scope_path(raw_project_dir, &cwd);
    let repo_root = raw_repo_root
        .map(|raw| resolve_scope_path(Some(raw), &cwd))
        .or_else(|| auto_detect_kuma_repo_root(&project_dir));

    let scope = build_scope(
        &cwd,
        &project_dir,
        repo_root.as_deref(),
        raw_project_dir.is_some(),
        raw_repo_root.is_some(),
    );
    let checks = build_checks(&project_dir, repo_root.as_deref(), probe);
    let statuses = checks
        .iter()
        .map(|check| (check.code.as_str(), check.status))
        .collect::<BTreeMap<_, _>>();
    let summaries = build_summaries(&statuses);
    let feature_inputs = FeatureReadinessInputs {
        project: &summaries.project,
        bootstrap: &summaries.bootstrap,
        repo: &summaries.repo,
        kubernetes: &summaries.kubernetes,
        universal: &summaries.universal,
        either_platform: &summaries.either_platform,
    };
    let features = feature_map
        .keys()
        .copied()
        .map(|feature| {
            let summary = feature_summary(feature, &feature_inputs);
            (feature, summary)
        })
        .collect();

    ReadinessReport {
        scope,
        checks,
        create: summaries.create.clone(),
        platforms: build_platform_readiness(&summaries),
        providers: build_provider_readiness(&summaries),
        features,
        profiles: build_profile_readiness(&summaries),
    }
}

struct CapabilitySummaries {
    create: ReadinessSummary,
    project: ReadinessSummary,
    bootstrap: ReadinessSummary,
    repo: ReadinessSummary,
    k3d: ReadinessSummary,
    remote: ReadinessSummary,
    kubernetes: ReadinessSummary,
    universal: ReadinessSummary,
    either_platform: ReadinessSummary,
}

fn build_scope(
    cwd: &Path,
    project_dir: &Path,
    repo_root: Option<&Path>,
    explicit_project_dir: bool,
    explicit_repo_root: bool,
) -> ReadinessScope {
    ReadinessScope {
        cwd: cwd.display().to_string(),
        project_dir: project_dir.display().to_string(),
        repo_root: repo_root.map(|path| path.display().to_string()),
        explicit_project_dir,
        explicit_repo_root,
    }
}

fn build_summaries(statuses: &BTreeMap<&str, ReadinessStatus>) -> CapabilitySummaries {
    let create = summary_from_codes(statuses, CREATE_REQUIREMENTS);
    let project = summary_from_codes(statuses, PROJECT_REQUIREMENTS);
    let bootstrap = summary_from_codes(statuses, BOOTSTRAP_REQUIREMENTS);
    let repo = summary_from_codes(statuses, REPO_REQUIREMENTS);
    let k3d = summary_from_codes(statuses, K3D_REQUIREMENTS);
    let remote = summary_from_codes(statuses, REMOTE_REQUIREMENTS);
    let kubernetes = any_of(&[&k3d, &remote]);
    let universal = summary_from_codes(statuses, UNIVERSAL_REQUIREMENTS);
    let either_platform = any_of(&[&kubernetes, &universal]);

    CapabilitySummaries {
        create,
        project,
        bootstrap,
        repo,
        k3d,
        remote,
        kubernetes,
        universal,
        either_platform,
    }
}

fn build_platform_readiness(
    summaries: &CapabilitySummaries,
) -> BTreeMap<String, PlatformReadiness> {
    BTreeMap::from([
        (
            Platform::Kubernetes.as_str().to_string(),
            PlatformReadiness {
                ready: summaries.kubernetes.ready,
                blocking_checks: summaries.kubernetes.blocking_checks.clone(),
            },
        ),
        (
            Platform::Universal.as_str().to_string(),
            PlatformReadiness {
                ready: summaries.universal.ready,
                blocking_checks: summaries.universal.blocking_checks.clone(),
            },
        ),
    ])
}

fn build_provider_readiness(summaries: &CapabilitySummaries) -> BTreeMap<String, ReadinessSummary> {
    BTreeMap::from([
        (
            ClusterProvider::K3d.as_str().to_string(),
            summaries.k3d.clone(),
        ),
        (
            ClusterProvider::Remote.as_str().to_string(),
            summaries.remote.clone(),
        ),
        (
            ClusterProvider::Compose.as_str().to_string(),
            summaries.universal.clone(),
        ),
    ])
}

fn build_profile_readiness(summaries: &CapabilitySummaries) -> Vec<ProfileReadiness> {
    vec![
        profile_readiness(
            "single-zone",
            Platform::Kubernetes,
            ClusterProvider::K3d,
            TopologyMode::SingleZone,
            &summaries.k3d,
        ),
        profile_readiness(
            "multi-zone",
            Platform::Kubernetes,
            ClusterProvider::K3d,
            TopologyMode::MultiZone,
            &summaries.k3d,
        ),
        profile_readiness(
            "single-zone",
            Platform::Kubernetes,
            ClusterProvider::Remote,
            TopologyMode::SingleZone,
            &summaries.remote,
        ),
        profile_readiness(
            "multi-zone",
            Platform::Kubernetes,
            ClusterProvider::Remote,
            TopologyMode::MultiZone,
            &summaries.remote,
        ),
        profile_readiness(
            "single-zone-universal",
            Platform::Universal,
            ClusterProvider::Compose,
            TopologyMode::SingleZone,
            &summaries.universal,
        ),
        profile_readiness(
            "multi-zone-universal",
            Platform::Universal,
            ClusterProvider::Compose,
            TopologyMode::MultiZone,
            &summaries.universal,
        ),
    ]
}

fn profile_readiness(
    name: &str,
    platform: Platform,
    provider: ClusterProvider,
    topology: TopologyMode,
    summary: &ReadinessSummary,
) -> ProfileReadiness {
    ProfileReadiness {
        name: name.into(),
        platform,
        provider,
        topology,
        ready: summary.ready,
        blocking_checks: summary.blocking_checks.clone(),
    }
}

const CREATE_REQUIREMENTS: &[&str] = &[
    "data_root_writable",
    "project_dir_exists",
    "suite_plugin_present",
];
const PROJECT_REQUIREMENTS: &[&str] = &[
    "project_dir_exists",
    "suite_plugin_present",
    "wrapper_install_target_available",
];
const BOOTSTRAP_REQUIREMENTS: &[&str] = &[
    "project_dir_exists",
    "suite_plugin_present",
    "wrapper_install_target_available",
];
const REPO_REQUIREMENTS: &[&str] = &[
    "repo_root_resolved",
    "repo_root_exists",
    "repo_is_kuma_checkout",
];
const K3D_REQUIREMENTS: &[&str] = &[
    "docker_binary_present",
    "docker_running",
    "make_binary_present",
    "k3d_binary_present",
    "kubectl_binary_present",
    "helm_binary_present",
    "repo_root_resolved",
    "repo_root_exists",
    "repo_is_kuma_checkout",
    "repo_make_contract_present",
];
const REMOTE_REQUIREMENTS: &[&str] = &[
    "docker_binary_present",
    "docker_running",
    "make_binary_present",
    "kubectl_binary_present",
    "helm_binary_present",
    "repo_root_resolved",
    "repo_root_exists",
    "repo_is_kuma_checkout",
    "repo_make_contract_present",
    "repo_remote_publish_contract_present",
];
const UNIVERSAL_REQUIREMENTS: &[&str] = &[
    "docker_binary_present",
    "docker_running",
    "docker_compose_available",
    "repo_root_resolved",
    "repo_root_exists",
    "repo_is_kuma_checkout",
];

fn resolve_scope_path(raw: Option<&str>, cwd: &Path) -> PathBuf {
    raw.map_or_else(
        || cwd.to_path_buf(),
        |value| {
            let path = PathBuf::from(value);
            if path.is_absolute() {
                path
            } else {
                cwd.join(path)
            }
        },
    )
}

fn auto_detect_kuma_repo_root(start: &Path) -> Option<PathBuf> {
    start.ancestors().find_map(|ancestor| {
        let go_mod = ancestor.join("go.mod");
        let text = fs::read_to_string(&go_mod).ok()?;
        if text.contains("github.com/kumahq/kuma") {
            Some(ancestor.to_path_buf())
        } else {
            None
        }
    })
}

fn build_checks(
    project_dir: &Path,
    repo_root: Option<&Path>,
    probe: &dyn CapabilityProbe,
) -> Vec<ReadinessCheck> {
    let path_env = probe.path_env();
    let home_dir = probe.home_dir();
    let project_exists = project_dir.is_dir();
    let plugin_root = project_dir.join(".claude").join("plugins").join("suite");
    let data_root = harness_data_root();
    let docker_present = probe.command_on_path("docker");
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
        check_docker_running(docker_present, probe),
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
        check_binary_present(
            "helm_binary_present",
            "Helm is available.",
            "Helm is missing.",
            "Install `helm` and ensure it is on PATH for Kubernetes profile setup.",
            "helm",
            probe,
        ),
        check_docker_compose_available(docker_present, probe),
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

fn check_docker_running(docker_present: bool, probe: &dyn CapabilityProbe) -> ReadinessCheck {
    if !docker_present {
        return skipped(
            "docker_running",
            ReadinessCheckScope::Machine,
            "Docker daemon check skipped because the Docker CLI is missing.",
            None,
            Some("Install Docker first, then rerun capabilities."),
        );
    }

    if probe.run_command_success("docker", &["info"]) {
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
    probe: &dyn CapabilityProbe,
) -> ReadinessCheck {
    if !docker_present {
        return skipped(
            "docker_compose_available",
            ReadinessCheckScope::Machine,
            "Docker Compose check skipped because the Docker CLI is missing.",
            None,
            Some("Install Docker first, then rerun capabilities."),
        );
    }

    if probe.run_command_success("docker", &["compose", "version"]) {
        pass(
            "docker_compose_available",
            ReadinessCheckScope::Machine,
            "Docker Compose is available.",
            None,
            None,
        )
    } else {
        fail(
            "docker_compose_available",
            ReadinessCheckScope::Machine,
            "Docker Compose is unavailable.",
            None,
            Some("Install Docker Compose support for universal profile setup."),
        )
    }
}

fn check_repo_root_resolved(repo_root: Option<&Path>) -> ReadinessCheck {
    if let Some(root) = repo_root {
        pass(
            "repo_root_resolved",
            ReadinessCheckScope::Repo,
            "Kuma repository root is resolved.",
            Some(root),
            None,
        )
    } else {
        fail(
            "repo_root_resolved",
            ReadinessCheckScope::Repo,
            "Kuma repository root is not resolved.",
            None,
            Some("Run from a Kuma checkout or pass `--repo-root`."),
        )
    }
}

fn check_repo_root_exists(repo_root: Option<&Path>) -> ReadinessCheck {
    let Some(root) = repo_root else {
        return skipped(
            "repo_root_exists",
            ReadinessCheckScope::Repo,
            "Repository path check skipped because the repo root is not resolved.",
            None,
            Some("Resolve the repo root first."),
        );
    };

    if root.is_dir() {
        pass(
            "repo_root_exists",
            ReadinessCheckScope::Repo,
            "Resolved repository root exists.",
            Some(root),
            None,
        )
    } else {
        fail(
            "repo_root_exists",
            ReadinessCheckScope::Repo,
            "Resolved repository root does not exist.",
            Some(root),
            Some("Verify the repo path or pass the correct `--repo-root`."),
        )
    }
}

fn check_repo_is_kuma_checkout(repo_root: Option<&Path>, repo_exists: bool) -> ReadinessCheck {
    let Some(root) = repo_root else {
        return skipped(
            "repo_is_kuma_checkout",
            ReadinessCheckScope::Repo,
            "Kuma checkout check skipped because the repo root is not resolved.",
            None,
            Some("Resolve the repo root first."),
        );
    };

    if !repo_exists {
        return skipped(
            "repo_is_kuma_checkout",
            ReadinessCheckScope::Repo,
            "Kuma checkout check skipped because the repo root path is missing.",
            Some(root),
            Some("Fix the repo root path first."),
        );
    }

    let go_mod = root.join("go.mod");
    match fs::read_to_string(&go_mod) {
        Ok(text) if text.contains("github.com/kumahq/kuma") => pass(
            "repo_is_kuma_checkout",
            ReadinessCheckScope::Repo,
            "Repository root is a Kuma checkout.",
            Some(&go_mod),
            None,
        ),
        Ok(_) => fail(
            "repo_is_kuma_checkout",
            ReadinessCheckScope::Repo,
            "Repository root is not a Kuma checkout.",
            Some(&go_mod),
            Some("Point `--repo-root` at a `github.com/kumahq/kuma` checkout."),
        ),
        Err(error) => fail(
            "repo_is_kuma_checkout",
            ReadinessCheckScope::Repo,
            format!("Repository checkout cannot be verified: {error}"),
            Some(&go_mod),
            Some("Ensure the repo root contains a readable `go.mod`."),
        ),
    }
}

fn check_repo_make_contract(repo_root: Option<&Path>, repo_is_kuma: bool) -> ReadinessCheck {
    let Some(root) = repo_root else {
        return skipped(
            "repo_make_contract_present",
            ReadinessCheckScope::Repo,
            "Kuma Make contract check skipped because the repo root is not resolved.",
            None,
            Some("Resolve the repo root first."),
        );
    };

    if !repo_is_kuma {
        return skipped(
            "repo_make_contract_present",
            ReadinessCheckScope::Repo,
            "Kuma Make contract check skipped because the repo root is not a verified Kuma checkout.",
            Some(root),
            Some("Use a current Kuma checkout before attempting cluster setup."),
        );
    }

    let k3d_makefile_path = root.join("mk").join("k3d.mk");
    let k8s_makefile_path = root.join("mk").join("k8s.mk");
    let expected_targets = [
        "k3d/cluster/start:",
        "k3d/cluster/deploy/helm:",
        "k3d/cluster/stop:",
    ];

    if !k3d_makefile_path.is_file() {
        return fail(
            "repo_make_contract_present",
            ReadinessCheckScope::Repo,
            "Kuma Make contract is missing `mk/k3d.mk`.",
            Some(&k3d_makefile_path),
            Some("Update the Kuma checkout to the current local-cluster Make contract."),
        );
    }
    if !k8s_makefile_path.is_file() {
        return fail(
            "repo_make_contract_present",
            ReadinessCheckScope::Repo,
            "Kuma Make contract is missing `mk/k8s.mk`.",
            Some(&k8s_makefile_path),
            Some("Update the Kuma checkout to the current local-cluster Make contract."),
        );
    }

    let cluster_targets_source = match fs::read_to_string(&k3d_makefile_path) {
        Ok(text) => text,
        Err(error) => {
            return fail(
                "repo_make_contract_present",
                ReadinessCheckScope::Repo,
                format!("Unable to read `mk/k3d.mk`: {error}"),
                Some(&k3d_makefile_path),
                Some("Ensure the Kuma Make files are readable."),
            );
        }
    };
    let cluster_variable_source = match fs::read_to_string(&k8s_makefile_path) {
        Ok(text) => text,
        Err(error) => {
            return fail(
                "repo_make_contract_present",
                ReadinessCheckScope::Repo,
                format!("Unable to read `mk/k8s.mk`: {error}"),
                Some(&k8s_makefile_path),
                Some("Ensure the Kuma Make files are readable."),
            );
        }
    };

    let missing_targets = expected_targets
        .iter()
        .copied()
        .filter(|needle| !cluster_targets_source.contains(needle))
        .collect::<Vec<_>>();
    if !missing_targets.is_empty() || !cluster_variable_source.contains("CLUSTER ?=") {
        let summary = if missing_targets.is_empty() {
            "Kuma Make contract is missing the canonical `CLUSTER` variable in `mk/k8s.mk`."
                .to_string()
        } else {
            format!(
                "Kuma Make contract is missing canonical k3d targets: {}.",
                missing_targets.join(", ")
            )
        };
        return fail(
            "repo_make_contract_present",
            ReadinessCheckScope::Repo,
            summary,
            Some(root),
            Some("Update the Kuma checkout to the current `k3d/cluster/*` contract."),
        );
    }

    pass(
        "repo_make_contract_present",
        ReadinessCheckScope::Repo,
        "Kuma Make contract matches the current `k3d/cluster/*` layout.",
        Some(root),
        None,
    )
}

fn check_repo_remote_publish_contract(
    repo_root: Option<&Path>,
    repo_is_kuma: bool,
) -> ReadinessCheck {
    let Some(root) = repo_root else {
        return skipped(
            "repo_remote_publish_contract_present",
            ReadinessCheckScope::Repo,
            "Remote publish contract check skipped because the repo root is not resolved.",
            None,
            Some("Resolve the repo root first."),
        );
    };

    if !repo_is_kuma {
        return skipped(
            "repo_remote_publish_contract_present",
            ReadinessCheckScope::Repo,
            "Remote publish contract check skipped because the repo root is not a verified Kuma checkout.",
            Some(root),
            Some("Use a current Kuma checkout before attempting remote setup."),
        );
    }

    let docker_makefile = root.join("mk").join("docker.mk");
    if !docker_makefile.is_file() {
        return fail(
            "repo_remote_publish_contract_present",
            ReadinessCheckScope::Repo,
            "Remote publish contract is missing `mk/docker.mk`.",
            Some(&docker_makefile),
            Some("Update the Kuma checkout to the current image publish contract."),
        );
    }

    let text = match fs::read_to_string(&docker_makefile) {
        Ok(text) => text,
        Err(error) => {
            return fail(
                "repo_remote_publish_contract_present",
                ReadinessCheckScope::Repo,
                format!("Unable to read `mk/docker.mk`: {error}"),
                Some(&docker_makefile),
                Some("Ensure the Kuma Make files are readable."),
            );
        }
    };

    let required = ["images/release:", "docker/push:", "manifests/json/release:"];
    let missing = required
        .iter()
        .copied()
        .filter(|needle| !text.contains(needle))
        .collect::<Vec<_>>();
    if !missing.is_empty() {
        return fail(
            "repo_remote_publish_contract_present",
            ReadinessCheckScope::Repo,
            format!(
                "Remote publish contract is missing required targets: {}.",
                missing.join(", ")
            ),
            Some(&docker_makefile),
            Some("Update the Kuma checkout so release image build/push targets are present."),
        );
    }

    pass(
        "repo_remote_publish_contract_present",
        ReadinessCheckScope::Repo,
        "Kuma repo exposes the current remote image publish contract.",
        Some(&docker_makefile),
        None,
    )
}

fn is_kuma_checkout(root: &Path) -> bool {
    let go_mod = root.join("go.mod");
    fs::read_to_string(go_mod).is_ok_and(|text| text.contains("github.com/kumahq/kuma"))
}

fn summary_from_codes(
    statuses: &BTreeMap<&str, ReadinessStatus>,
    codes: &[&str],
) -> ReadinessSummary {
    let ready = codes
        .iter()
        .all(|code| statuses.get(code).copied() == Some(ReadinessStatus::Pass));
    let blocking_checks = codes
        .iter()
        .filter(|code| statuses.get(**code).copied() == Some(ReadinessStatus::Fail))
        .map(|code| (*code).to_string())
        .collect();
    ReadinessSummary {
        ready,
        blocking_checks,
    }
}

fn any_of(summaries: &[&ReadinessSummary]) -> ReadinessSummary {
    if summaries.iter().any(|summary| summary.ready) {
        return ReadinessSummary {
            ready: true,
            blocking_checks: vec![],
        };
    }

    let blocking_checks = summaries
        .iter()
        .flat_map(|summary| summary.blocking_checks.iter().cloned())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    ReadinessSummary {
        ready: false,
        blocking_checks,
    }
}

struct FeatureReadinessInputs<'a> {
    project: &'a ReadinessSummary,
    bootstrap: &'a ReadinessSummary,
    repo: &'a ReadinessSummary,
    kubernetes: &'a ReadinessSummary,
    universal: &'a ReadinessSummary,
    either_platform: &'a ReadinessSummary,
}

fn feature_summary(feature: Feature, inputs: &FeatureReadinessInputs<'_>) -> ReadinessSummary {
    match feature {
        Feature::Bootstrap => inputs.bootstrap.clone(),
        Feature::HookSystem
        | Feature::Observation
        | Feature::PreCompactHandoff
        | Feature::SessionLifecycle => inputs.project.clone(),
        Feature::GatewayApi
        | Feature::HelmSettings
        | Feature::MultiZoneKdsAutoConfig
        | Feature::NamespaceRestart => inputs.kubernetes.clone(),
        Feature::DataplaneTokens | Feature::ServiceContainers | Feature::TransparentProxy => {
            inputs.universal.clone()
        }
        Feature::Kumactl => inputs.repo.clone(),
        Feature::ApiAccess
        | Feature::ClusterCheck
        | Feature::ClusterManagement
        | Feature::ContainerLogs
        | Feature::EnvoyAdmin
        | Feature::ManifestApply
        | Feature::ManifestValidate
        | Feature::RunLifecycle
        | Feature::StateCapture
        | Feature::StatusReport
        | Feature::TrackedRecording => inputs.either_platform.clone(),
        Feature::BugFoundGate
        | Feature::GlobalDelay
        | Feature::IdempotentGroupReporting
        | Feature::JsonDiff
        | Feature::ProgressHeartbeat
        | Feature::TaskManagement => ReadinessSummary {
            ready: true,
            blocking_checks: vec![],
        },
    }
}

fn pass(
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

fn fail(
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

fn skipped(
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

fn command_on_path(command: &str, path_env: &str) -> bool {
    let candidate = Path::new(command);
    if candidate.components().count() > 1 {
        return candidate.is_file();
    }

    env::split_paths(path_env)
        .map(|dir| dir.join(command))
        .any(|path| path.is_file())
}
