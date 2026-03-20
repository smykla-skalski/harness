use std::collections::HashMap;
use std::path::Path;

use super::*;

#[test]
fn helm_setting_parses_cli_arg() {
    let setting = HelmSetting::from_cli_arg("controlPlane.mode=global").unwrap();
    assert_eq!(setting.key, "controlPlane.mode");
    assert_eq!(setting.value, "global");
    assert_eq!(setting.to_cli_arg(), "controlPlane.mode=global");
}

#[test]
fn helm_setting_rejects_invalid_arg() {
    assert!(HelmSetting::from_cli_arg("missingequals").is_err());
    assert!(HelmSetting::from_cli_arg("=value").is_err());
}

#[test]
fn fake_package_deployer_tracks_release_state() {
    let fake = FakePackageDeployer::new();
    let settings = vec![HelmSetting {
        key: "a.b".into(),
        value: "c".into(),
    }];

    let deployed = fake
        .upgrade_install("kuma", "kumahq/kuma", Some("kuma-system"), &settings, &[])
        .unwrap();
    assert_eq!(deployed.release, "kuma");

    let releases = fake.releases.lock().expect("lock poisoned");
    assert_eq!(releases.get("kuma"), Some(&settings));
}

#[test]
fn fake_package_deployer_uninstall_removes_release() {
    let fake = FakePackageDeployer::new();
    fake.upgrade_install("kuma", "kumahq/kuma", None, &[], &[])
        .unwrap();

    fake.uninstall("kuma", None, &[]).unwrap();

    assert!(
        !fake
            .releases
            .lock()
            .expect("lock poisoned")
            .contains_key("kuma")
    );
}

#[test]
fn helm_types_are_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}

    assert_send_sync::<HelmDeployer>();
    assert_send_sync::<FakePackageDeployer>();
}

mod contracts {
    use super::*;

    fn contract_upgrade_install_returns_deploy_result(deployer: &dyn PackageDeployer) {
        let result = deployer
            .upgrade_install(
                "contract-test",
                "oci://example/chart",
                None,
                &[],
                &["--dry-run"],
            )
            .expect("upgrade_install should succeed");
        assert_eq!(result.release, "contract-test");
        assert_eq!(result.chart, "oci://example/chart");
    }

    fn contract_uninstall_nonexistent_is_tolerant(deployer: &dyn PackageDeployer) {
        let _ = deployer.uninstall("nonexistent-contract-test-release", None, &[]);
    }

    fn contract_run_target_returns_result(deployer: &dyn PackageDeployer) {
        let result = deployer
            .run_target(Path::new("/repo"), "test", &HashMap::new())
            .expect("run_target should succeed");
        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn fake_satisfies_upgrade_install() {
        contract_upgrade_install_returns_deploy_result(&FakePackageDeployer::new());
    }

    #[test]
    fn fake_satisfies_uninstall_nonexistent() {
        contract_uninstall_nonexistent_is_tolerant(&FakePackageDeployer::new());
    }

    #[test]
    fn fake_satisfies_run_target() {
        contract_run_target_returns_result(&FakePackageDeployer::new());
    }
}
