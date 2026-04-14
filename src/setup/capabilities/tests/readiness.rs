use super::*;

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
        with_vars([("HARNESS_CONTAINER_RUNTIME", Some("docker-cli"))], || {
            build_report(
                Some(project_dir.to_str().unwrap()),
                Some(repo_root.to_str().unwrap()),
                &FakeProbe::ready(&home).without_command("docker"),
            )
        })
    });

    assert!(report.readiness.create.ready);
    assert!(!report.readiness.platforms["kubernetes"].ready);
    assert!(!report.readiness.platforms["universal"].ready);
    assert!(
        report.readiness.platforms["kubernetes"]
            .blocking_checks
            .contains(&"docker_binary_present".to_string())
    );
    assert!(
        report.readiness.platforms["universal"]
            .blocking_checks
            .is_empty()
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
fn readiness_keeps_universal_ready_with_bollard_when_docker_cli_is_missing() {
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
        with_vars([("HARNESS_CONTAINER_RUNTIME", Some("bollard"))], || {
            build_report(
                Some(project_dir.to_str().unwrap()),
                Some(repo_root.to_str().unwrap()),
                &FakeProbe::ready(&home).without_command("docker"),
            )
        })
    });

    assert!(!report.readiness.platforms["kubernetes"].ready);
    assert!(report.readiness.platforms["universal"].ready);
    assert_eq!(
        report
            .readiness
            .checks
            .iter()
            .find(|check| check.code == "docker_running")
            .unwrap()
            .status,
        ReadinessStatus::Pass
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

    assert!(!report.readiness.platforms["kubernetes"].ready);
    assert!(
        report.readiness.platforms["kubernetes"]
            .blocking_checks
            .contains(&"repo_make_contract_present".to_string())
    );
    assert!(
        report.readiness.providers["remote"]
            .blocking_checks
            .contains(&"repo_remote_publish_contract_present".to_string())
            || report.readiness.providers["remote"]
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

#[test]
fn readiness_keeps_remote_provider_ready_when_k3d_is_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let repo_root = tmp.path().join("repo-root");
    let project_dir = tmp.path().join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(home.join("bin")).unwrap();
    fs::create_dir_all(&project_dir).unwrap();
    write_suite_plugin(&project_dir);
    write_current_kuma_contract(&repo_root);

    let probe = FakeProbe::ready(&home).without_command("k3d");
    let report = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            Some(repo_root.to_str().unwrap()),
            &probe,
        )
    });

    assert!(!report.readiness.providers["k3d"].ready);
    assert!(report.readiness.providers["remote"].ready);
    assert!(report.readiness.platforms["kubernetes"].ready);
    assert!(
        report
            .readiness
            .profiles
            .iter()
            .any(|profile| profile.name == "single-zone"
                && profile.provider == ClusterProvider::Remote
                && profile.ready)
    );
}

#[test]
fn readiness_keeps_kubernetes_ready_with_native_runtime_when_kubectl_is_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let (home_dir, project_dir) = prepare_project_root_with_contract(tmp.path());

    let report = with_data_root(tmp.path(), || {
        build_report(
            Some(project_dir.to_str().unwrap()),
            None,
            &FakeProbe::ready(&home_dir).without_command("kubectl"),
        )
    });

    assert!(report.readiness.platforms["kubernetes"].ready);
    assert!(report.readiness.providers["k3d"].ready);
    assert!(report.readiness.providers["remote"].ready);

    let kubectl_check = report
        .readiness
        .checks
        .iter()
        .find(|check| check.code == "kubectl_binary_present")
        .unwrap();
    assert_eq!(kubectl_check.status, ReadinessStatus::Fail);

    let runtime_check = report
        .readiness
        .checks
        .iter()
        .find(|check| check.code == "kubernetes_runtime_ready")
        .unwrap();
    assert_eq!(runtime_check.status, ReadinessStatus::Pass);
}

#[test]
fn readiness_blocks_kubernetes_when_kubectl_cli_backend_is_selected_without_kubectl() {
    let tmp = tempfile::tempdir().unwrap();
    let (home_dir, project_dir) = prepare_project_root_with_contract(tmp.path());

    let report = with_data_root(tmp.path(), || {
        with_vars(
            [("HARNESS_KUBERNETES_RUNTIME", Some("kubectl-cli"))],
            || {
                build_report(
                    Some(project_dir.to_str().unwrap()),
                    None,
                    &FakeProbe::ready(&home_dir).without_command("kubectl"),
                )
            },
        )
    });

    assert!(!report.readiness.platforms["kubernetes"].ready);
    assert!(!report.readiness.providers["k3d"].ready);
    assert!(!report.readiness.providers["remote"].ready);
    assert!(
        report.readiness.platforms["kubernetes"]
            .blocking_checks
            .contains(&"kubernetes_runtime_ready".to_string())
    );

    let runtime_check = report
        .readiness
        .checks
        .iter()
        .find(|check| check.code == "kubernetes_runtime_ready")
        .unwrap();
    assert_eq!(runtime_check.status, ReadinessStatus::Fail);
}
