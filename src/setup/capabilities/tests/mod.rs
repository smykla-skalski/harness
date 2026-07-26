use std::fs;
use std::path::{Path, PathBuf};

use temp_env::with_vars;

use super::capabilities;
use super::data::features;
use super::model::{CapabilitiesReport, Feature, ReadinessStatus};
use super::readiness::CapabilityProbe;

mod commands;
mod readiness;

#[derive(Debug, Clone)]
struct FakeProbe {
    path_env: String,
    home_dir: PathBuf,
}

impl FakeProbe {
    fn ready(home_dir: &Path) -> Self {
        Self {
            path_env: home_dir.join("bin").display().to_string(),
            home_dir: home_dir.to_path_buf(),
        }
    }
}

impl CapabilityProbe for FakeProbe {
    fn path_env(&self) -> String {
        self.path_env.clone()
    }

    fn home_dir(&self) -> PathBuf {
        self.home_dir.clone()
    }
}

fn create_home_dir(tmp: &Path) -> PathBuf {
    let home_dir = tmp.join("home");
    fs::create_dir_all(home_dir.join("bin")).unwrap();
    home_dir
}

fn prepare_project_root(tmp: &Path) -> (PathBuf, PathBuf) {
    let home_dir = create_home_dir(tmp);
    let project_dir = tmp.join("project");
    fs::create_dir_all(&project_dir).unwrap();
    (home_dir, project_dir)
}

fn build_report(project_dir: Option<&str>, probe: &FakeProbe) -> CapabilitiesReport {
    super::build_report_with_probe(project_dir, probe)
}

fn with_data_root<T>(root: &Path, run: impl FnOnce() -> T) -> T {
    with_vars([("XDG_DATA_HOME", Some(root.to_str().unwrap()))], run)
}

fn assert_report_has_static_sections(caps: &CapabilitiesReport) {
    assert!(!caps.features.is_empty());
}

fn assert_report_has_readiness_sections(caps: &CapabilitiesReport) {
    assert!(!caps.readiness.checks.is_empty());
    assert!(!caps.readiness.features.is_empty());
}

#[test]
fn capabilities_returns_zero() {
    let tmp = tempfile::tempdir().unwrap();
    with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap()))],
        || {
            assert_eq!(capabilities(None).unwrap(), 0);
        },
    );
}

#[test]
fn output_contains_expected_sections() {
    let tmp = tempfile::tempdir().unwrap();
    let (home_dir, project_dir) = prepare_project_root(tmp.path());

    let caps = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            &FakeProbe::ready(&home_dir),
        )
    });
    assert_report_has_static_sections(&caps);
    assert_report_has_readiness_sections(&caps);
}

#[test]
fn readiness_succeeds_without_suite_plugin() {
    let tmp = tempfile::tempdir().unwrap();
    let home_dir = create_home_dir(tmp.path());
    let project_dir = tmp.path().join("project");
    fs::create_dir_all(&project_dir).unwrap();

    let caps = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            &FakeProbe::ready(&home_dir),
        )
    });

    assert!(caps.readiness.features[&Feature::Bootstrap].ready);
    assert!(
        !caps
            .readiness
            .checks
            .iter()
            .any(|check| check.code.contains("plugin"))
    );
}

#[test]
fn lifecycle_features_use_top_level_commands() {
    let feature_map = features();
    let pre_compact = feature_map.get(&Feature::PreCompactHandoff).unwrap();
    assert_eq!(
        pre_compact.command.as_deref(),
        Some("harness-hook pre-compact")
    );

    let session = feature_map.get(&Feature::SessionLifecycle).unwrap();
    assert_eq!(
        session.commands.as_deref(),
        Some(
            &[
                "harness-hook session-start".to_string(),
                "harness-hook session-stop".to_string(),
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

    let caps = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            &FakeProbe::ready(&home),
        )
    });
    let json = serde_json::to_string(&caps).unwrap();
    let deserialized: CapabilitiesReport = serde_json::from_str(&json).unwrap();
    assert_eq!(caps, deserialized);
}

// The sibling command test rejects any entry naming a command the binaries no
// longer accept, which covers every retired feature that carried one. This list
// holds the rest: capabilities described without a command, where nothing else
// would notice them coming back.
#[test]
fn features_exclude_retired_capabilities() {
    let feature_map = features();
    assert!(feature_map.contains_key(&Feature::Bootstrap));
    let keys = serde_json::to_value(&feature_map).unwrap();
    let keys = keys.as_object().unwrap();
    for retired in [
        "api_access",
        "bug_found_gate",
        "cluster_check",
        "cluster_management",
        "container_logs",
        "dataplane_tokens",
        "envoy_admin",
        "gateway_api",
        "helm_settings",
        "kumactl",
        "manifest_apply",
        "manifest_validate",
        "multi_zone_kds_auto_config",
        "namespace_restart",
        "service_containers",
        "state_capture",
        "status_report",
        "transparent_proxy",
    ] {
        assert!(!keys.contains_key(retired), "{retired} should be retired");
    }
}

#[test]
fn feature_count_is_current() {
    let feature_map = features();
    assert_eq!(
        feature_map.len(),
        7,
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
