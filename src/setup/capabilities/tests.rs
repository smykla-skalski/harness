use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use temp_env::with_vars;

use crate::kernel::topology::Platform;

use super::capabilities;
use super::data::{features, platforms};
use super::model::{CapabilitiesReport, Feature, ReadinessStatus};
use super::readiness::CapabilityProbe;

#[derive(Debug, Clone)]
struct FakeProbe {
    path_env: String,
    home_dir: PathBuf,
    commands: BTreeSet<String>,
    successful_invocations: BTreeSet<String>,
}

impl FakeProbe {
    fn ready(home_dir: &Path) -> Self {
        Self {
            path_env: home_dir.join("bin").display().to_string(),
            home_dir: home_dir.to_path_buf(),
            commands: ["docker", "make", "k3d", "kubectl", "helm"]
                .into_iter()
                .map(str::to_string)
                .collect(),
            successful_invocations: ["docker info", "docker compose version"]
                .into_iter()
                .map(str::to_string)
                .collect(),
        }
    }

    fn without_command(mut self, command: &str) -> Self {
        self.commands.remove(command);
        self
    }
}

impl CapabilityProbe for FakeProbe {
    fn path_env(&self) -> String {
        self.path_env.clone()
    }

    fn home_dir(&self) -> PathBuf {
        self.home_dir.clone()
    }

    fn command_on_path(&self, command: &str) -> bool {
        self.commands.contains(command)
    }

    fn run_command_success(&self, program: &str, args: &[&str]) -> bool {
        let mut invocation = program.to_string();
        if !args.is_empty() {
            invocation.push(' ');
            invocation.push_str(&args.join(" "));
        }
        self.successful_invocations.contains(&invocation)
    }
}

fn write_suite_plugin(project_dir: &Path) {
    fs::create_dir_all(project_dir.join(".claude/plugins/suite")).unwrap();
}

fn write_current_kuma_contract(repo_root: &Path) {
    fs::create_dir_all(repo_root.join("mk")).unwrap();
    fs::write(
        repo_root.join("go.mod"),
        "module github.com/kumahq/kuma\n\ngo 1.24\n",
    )
    .unwrap();
    fs::write(
        repo_root.join("mk/k3d.mk"),
        "k3d/cluster/start:\n\t@echo start\n\nk3d/cluster/deploy/helm:\n\t@echo deploy\n\nk3d/cluster/stop:\n\t@echo stop\n",
    )
    .unwrap();
    fs::write(repo_root.join("mk/k8s.mk"), "CLUSTER ?= kuma-1\n").unwrap();
}

fn create_home_dir(tmp: &Path) -> PathBuf {
    let home_dir = tmp.join("home");
    fs::create_dir_all(home_dir.join("bin")).unwrap();
    home_dir
}

fn prepare_project_root_with_contract(tmp: &Path) -> (PathBuf, PathBuf) {
    let home_dir = create_home_dir(tmp);
    let project_dir = tmp.join("project");
    fs::create_dir_all(&project_dir).unwrap();
    write_suite_plugin(&project_dir);
    write_current_kuma_contract(&project_dir);
    (home_dir, project_dir)
}

fn prepare_nested_kuma_project(tmp: &Path) -> (PathBuf, PathBuf, PathBuf) {
    let home_dir = create_home_dir(tmp);
    let repo_root = tmp.join("repo-root");
    let project_dir = repo_root.join("worktree");
    fs::create_dir_all(&project_dir).unwrap();
    write_suite_plugin(&project_dir);
    write_current_kuma_contract(&repo_root);
    (home_dir, repo_root, project_dir)
}

fn build_report(
    project_dir: Option<&str>,
    repo_root: Option<&str>,
    probe: &FakeProbe,
) -> CapabilitiesReport {
    super::build_report_with_probe(project_dir, repo_root, probe)
}

fn with_data_root<T>(root: &Path, run: impl FnOnce() -> T) -> T {
    with_vars([("XDG_DATA_HOME", Some(root.to_str().unwrap()))], run)
}

fn assert_report_has_static_sections(caps: &CapabilitiesReport) {
    assert!(caps.create.available);
    assert!(!caps.cluster_topologies.is_empty());
    assert!(!caps.features.is_empty());
    assert!(!caps.platforms.is_empty());
}

fn assert_report_has_readiness_sections(caps: &CapabilitiesReport) {
    assert!(caps.readiness.create.ready);
    assert!(!caps.readiness.checks.is_empty());
    assert!(!caps.readiness.profiles.is_empty());
}

fn assert_ready_profiles(report: &CapabilitiesReport) {
    assert!(report.readiness.platforms["kubernetes"].ready);
    assert!(report.readiness.platforms["universal"].ready);
    assert!(report.readiness.features[&Feature::Bootstrap].ready);
    assert!(report.readiness.features[&Feature::GatewayApi].ready);
    assert!(report.readiness.features[&Feature::DataplaneTokens].ready);
    assert!(
        report
            .readiness
            .profiles
            .iter()
            .all(|profile| profile.ready)
    );
}

#[test]
fn capabilities_returns_zero() {
    let tmp = tempfile::tempdir().unwrap();
    with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap()))],
        || {
            assert_eq!(capabilities(None, None).unwrap(), 0);
        },
    );
}

#[test]
fn output_contains_expected_sections() {
    let tmp = tempfile::tempdir().unwrap();
    let (home_dir, project_dir) = prepare_project_root_with_contract(tmp.path());

    let caps = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            None,
            &FakeProbe::ready(&home_dir),
        )
    });
    assert_report_has_static_sections(&caps);
    assert_report_has_readiness_sections(&caps);
}

#[test]
fn platforms_lists_both() {
    let platform_list = platforms();
    let names: Vec<Platform> = platform_list.iter().map(|info| info.name).collect();
    assert!(names.contains(&Platform::Kubernetes));
    assert!(names.contains(&Platform::Universal));
}

#[test]
fn features_include_universal_only_items() {
    let feature_map = features();
    let tokens = feature_map.get(&Feature::DataplaneTokens).unwrap();
    assert!(tokens.available);
    let platforms = tokens.platforms.as_ref().unwrap();
    assert_eq!(platforms.len(), 1);
    assert_eq!(platforms[0], Platform::Universal);
}

#[test]
fn lifecycle_features_use_top_level_commands() {
    let feature_map = features();
    let pre_compact = feature_map.get(&Feature::PreCompactHandoff).unwrap();
    assert_eq!(pre_compact.command.as_deref(), Some("harness pre-compact"));

    let session = feature_map.get(&Feature::SessionLifecycle).unwrap();
    assert_eq!(
        session.commands.as_deref(),
        Some(
            &[
                "harness session-start".to_string(),
                "harness session-stop".to_string(),
            ][..]
        )
    );
}

#[test]
fn json_round_trip() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let project_dir = tmp.path().join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(home.join("bin")).unwrap();
    fs::create_dir_all(&project_dir).unwrap();
    write_suite_plugin(&project_dir);
    write_current_kuma_contract(&project_dir);

    let caps = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            None,
            &FakeProbe::ready(&home),
        )
    });
    let json = serde_json::to_string(&caps).unwrap();
    let deserialized: CapabilitiesReport = serde_json::from_str(&json).unwrap();
    assert_eq!(caps, deserialized);
}

#[test]
fn features_include_api_cluster_bootstrap() {
    let feature_map = features();
    assert!(feature_map.contains_key(&Feature::ApiAccess));
    assert!(feature_map.contains_key(&Feature::Bootstrap));
    assert!(feature_map.contains_key(&Feature::ClusterManagement));
}

#[test]
fn feature_count_is_current() {
    let feature_map = features();
    assert_eq!(
        feature_map.len(),
        30,
        "feature count changed - update this test"
    );
}

#[test]
fn feature_keys_are_snake_case() {
    let feature_map = features();
    let value = serde_json::to_value(&feature_map).unwrap();
    let map = value.as_object().unwrap();
    for key in map.keys() {
        assert!(
            key.chars()
                .all(|character| character.is_ascii_lowercase() || character == '_'),
            "feature key {key:?} is not snake_case"
        );
    }
}

#[test]
fn readiness_auto_detects_repo_root_and_marks_profiles_ready() {
    let tmp = tempfile::tempdir().unwrap();
    let (home_dir, repo_root, project_dir) = prepare_nested_kuma_project(tmp.path());

    let report = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            None,
            &FakeProbe::ready(&home_dir),
        )
    });

    assert_eq!(
        report.readiness.scope.repo_root.as_deref(),
        Some(repo_root.to_str().unwrap())
    );
    assert!(report.readiness.create.ready);
    assert_ready_profiles(&report);
}

#[test]
fn readiness_marks_create_unready_when_project_plugin_is_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let repo_root = tmp.path().join("repo-root");
    let project_dir = tmp.path().join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(home.join("bin")).unwrap();
    fs::create_dir_all(&project_dir).unwrap();
    write_current_kuma_contract(&repo_root);

    let report = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            Some(repo_root.to_str().unwrap()),
            &FakeProbe::ready(&home),
        )
    });

    assert!(!report.readiness.create.ready);
    assert_eq!(
        report.readiness.create.blocking_checks,
        vec!["suite_plugin_present".to_string()]
    );
    assert!(!report.readiness.features[&Feature::Bootstrap].ready);
}

#[test]
fn readiness_blocks_platforms_when_docker_is_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let repo_root = tmp.path().join("repo-root");
    let project_dir = tmp.path().join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(home.join("bin")).unwrap();
    fs::create_dir_all(&project_dir).unwrap();
    write_suite_plugin(&project_dir);
    write_current_kuma_contract(&repo_root);

    let report = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            Some(repo_root.to_str().unwrap()),
            &FakeProbe::ready(&home).without_command("docker"),
        )
    });

    assert!(report.readiness.create.ready);
    assert!(!report.readiness.platforms["kubernetes"].ready);
    assert!(!report.readiness.platforms["universal"].ready);
    assert!(
        report.readiness.platforms["kubernetes"]
            .blocking_checks
            .contains(&"docker_binary_present".to_string())
    );
    assert_eq!(
        report
            .readiness
            .checks
            .iter()
            .find(|check| check.code == "docker_running")
            .unwrap()
            .status,
        ReadinessStatus::Skipped
    );
}

#[test]
fn readiness_marks_repo_contract_unready_when_targets_are_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let repo_root = tmp.path().join("repo-root");
    let project_dir = tmp.path().join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(home.join("bin")).unwrap();
    fs::create_dir_all(&project_dir).unwrap();
    write_suite_plugin(&project_dir);
    fs::create_dir_all(repo_root.join("mk")).unwrap();
    fs::write(
        repo_root.join("go.mod"),
        "module github.com/kumahq/kuma\n\ngo 1.24\n",
    )
    .unwrap();
    fs::write(repo_root.join("mk/k3d.mk"), "k3d/start:\n\t@echo old\n").unwrap();
    fs::write(repo_root.join("mk/k8s.mk"), "KIND_CLUSTER_NAME ?= kuma-1\n").unwrap();

    let report = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            Some(repo_root.to_str().unwrap()),
            &FakeProbe::ready(&home),
        )
    });

    assert!(!report.readiness.platforms["kubernetes"].ready);
    assert!(
        report.readiness.platforms["kubernetes"]
            .blocking_checks
            .contains(&"repo_make_contract_present".to_string())
    );
}

#[test]
fn readiness_distinguishes_platform_specific_features() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let repo_root = tmp.path().join("repo-root");
    let project_dir = tmp.path().join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(home.join("bin")).unwrap();
    fs::create_dir_all(&project_dir).unwrap();
    write_suite_plugin(&project_dir);
    write_current_kuma_contract(&repo_root);

    let probe = FakeProbe::ready(&home)
        .without_command("k3d")
        .without_command("kubectl")
        .without_command("helm")
        .without_command("make");
    let report = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            Some(repo_root.to_str().unwrap()),
            &probe,
        )
    });

    assert!(!report.readiness.platforms["kubernetes"].ready);
    assert!(report.readiness.platforms["universal"].ready);
    assert!(!report.readiness.features[&Feature::GatewayApi].ready);
    assert!(report.readiness.features[&Feature::DataplaneTokens].ready);
    assert!(report.readiness.features[&Feature::ManifestApply].ready);
}
