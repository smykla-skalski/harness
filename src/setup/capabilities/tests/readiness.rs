use std::collections::BTreeSet;

use super::super::readiness::{BOOTSTRAP_REQUIREMENTS, PROJECT_REQUIREMENTS};
use super::*;

/// Checks that gate nothing and describe nothing are how this report goes stale:
/// #670 retired four capability summaries and left the five checks that fed them
/// behind, so the report went on telling readers to repair an environment for
/// capabilities the product had dropped. A check reaches the report only if some
/// capability's readiness depends on it, or if it is named here as a fact worth
/// reporting on its own.
const INFORMATIONAL_CHECKS: &[&str] = &["data_root_writable"];

fn accounted_check_codes() -> BTreeSet<&'static str> {
    PROJECT_REQUIREMENTS
        .iter()
        .chain(BOOTSTRAP_REQUIREMENTS)
        .chain(INFORMATIONAL_CHECKS)
        .copied()
        .collect()
}

fn ready_report(tmp: &Path) -> CapabilitiesReport {
    let (home_dir, project_dir) = prepare_project_root(tmp);
    with_data_root(tmp, || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            &FakeProbe::ready(&home_dir),
        )
    })
}

#[test]
fn readiness_reports_the_project_scope_it_resolved() {
    let tmp = tempfile::tempdir().unwrap();
    let report = ready_report(tmp.path());

    assert_eq!(
        report.readiness.scope.project_dir,
        tmp.path().join("project").to_str().unwrap()
    );
    assert!(report.readiness.scope.explicit_project_dir);
    assert!(report.readiness.features[&Feature::Bootstrap].ready);
}

#[test]
fn readiness_stays_ready_when_project_plugin_is_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let report = ready_report(tmp.path());

    assert!(report.readiness.features[&Feature::Bootstrap].ready);
    assert!(
        !report
            .readiness
            .checks
            .iter()
            .any(|check| check.code.contains("plugin"))
    );
}

#[test]
fn readiness_blocks_the_project_capabilities_when_the_project_dir_is_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let home_dir = create_home_dir(tmp.path());
    let missing = tmp.path().join("absent");

    let report = with_data_root(tmp.path(), || {
        build_report(
            Some(missing.to_str().unwrap()),
            &FakeProbe::ready(&home_dir),
        )
    });

    let project_dir_status = report
        .readiness
        .checks
        .iter()
        .find(|check| check.code == "project_dir_exists")
        .map(|check| check.status);
    assert_eq!(project_dir_status, Some(ReadinessStatus::Fail));
    assert_eq!(
        report.readiness.features[&Feature::Bootstrap].blocking_checks,
        vec!["project_dir_exists".to_string()]
    );
}

#[test]
fn every_emitted_check_gates_a_capability_or_is_declared_informational() {
    let tmp = tempfile::tempdir().unwrap();
    let report = ready_report(tmp.path());

    let emitted: BTreeSet<&str> = report
        .readiness
        .checks
        .iter()
        .map(|check| check.code.as_str())
        .collect();
    assert!(!emitted.is_empty(), "the report emitted no checks at all");

    let accounted = accounted_check_codes();
    let orphaned: Vec<&&str> = emitted.difference(&accounted).collect();
    assert!(
        orphaned.is_empty(),
        "these checks gate no capability and are not declared informational: {orphaned:?}"
    );

    let stale: Vec<&&str> = accounted.difference(&emitted).collect();
    assert!(
        stale.is_empty(),
        "these codes are required or declared but no longer emitted: {stale:?}"
    );
}
