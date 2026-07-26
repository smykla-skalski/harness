use super::*;

#[test]
fn readiness_auto_detects_repo_root() {
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
    assert!(report.readiness.features[&Feature::Bootstrap].ready);
}

#[test]
fn readiness_stays_ready_when_project_plugin_is_missing() {
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
fn readiness_marks_repo_contract_unready_when_targets_are_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let repo_root = tmp.path().join("repo-root");
    let project_dir = tmp.path().join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(home.join("bin")).unwrap();
    fs::create_dir_all(&project_dir).unwrap();
    fs::create_dir_all(repo_root.join("mk")).unwrap();
    fs::write(
        repo_root.join("go.mod"),
        "module github.com/kumahq/kuma\n\ngo 1.24\n",
    )
    .unwrap();
    fs::write(repo_root.join("mk/k3d.mk"), "k3d/start:\n\t@echo old\n").unwrap();
    fs::write(repo_root.join("mk/k8s.mk"), "KIND_CLUSTER_NAME ?= kuma-1\n").unwrap();
    fs::write(
        repo_root.join("mk/docker.mk"),
        "docker/push:\n\t@echo old\n",
    )
    .unwrap();

    let report = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            Some(repo_root.to_str().unwrap()),
            &FakeProbe::ready(&home),
        )
    });

    let status = |code: &str| {
        report
            .readiness
            .checks
            .iter()
            .find(|check| check.code == code)
            .map(|check| check.status)
    };

    assert_eq!(
        status("repo_make_contract_present"),
        Some(ReadinessStatus::Fail)
    );
    assert_eq!(
        status("repo_remote_publish_contract_present"),
        Some(ReadinessStatus::Fail)
    );
}
