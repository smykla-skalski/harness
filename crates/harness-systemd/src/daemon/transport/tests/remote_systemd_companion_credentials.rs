//! Credential preflight and feature-gate coverage for companion installation.

use std::fs::{self, Permissions};
use std::os::unix::fs::{PermissionsExt as _, symlink};
use std::path::Path;

use tempfile::tempdir;

use crate::app::command_context::{AppContext, Execute as _};

use super::super::remote_systemd::DaemonRemoteSystemdInstallArgs;
use super::super::remote_systemd::{
    RemoteSystemdInstallPlan, validate_companion_credential_source_for_tests,
};
use super::super::remote_systemd_lifecycle::{
    RemoteSystemdCommandOutput, install_remote_systemd_with,
};
use super::remote_systemd_plan::install_args;
use super::trusted_test_executable;

const COMPANION_TOKEN_SOURCE: &str = "/etc/harness/companion-auth-token";

#[test]
fn private_companion_credential_source_is_accepted() {
    let temp = tempdir().expect("temp dir");
    let source = temp.path().join("companion-auth-token");
    fs::write(&source, "private-daemon-panel-token-0123456789").expect("write credential source");
    fs::set_permissions(&source, Permissions::from_mode(0o600))
        .expect("make credential source private");

    assert_eq!(
        companion_dry_run_args(&source)
            .execute(&AppContext)
            .expect("private regular credential source"),
        0
    );
}

#[test]
fn dry_run_rejects_group_or_other_access_to_companion_credential_source() {
    let temp = tempdir().expect("temp dir");
    let source = temp.path().join("companion-auth-token");
    fs::write(&source, "private-daemon-panel-token-0123456789").expect("write credential source");
    fs::set_permissions(&source, Permissions::from_mode(0o644))
        .expect("make credential source exposed");

    let error = companion_dry_run_args(&source)
        .execute(&AppContext)
        .expect_err("group-readable credential source must be refused")
        .to_string();

    assert!(error.contains("owner-readable and private"), "{error}");
    assert!(error.contains("0644"), "{error}");
}

#[test]
fn dry_run_rejects_a_credential_below_a_writable_ancestor() {
    let temp = tempdir().expect("temp dir");
    let writable = temp.path().join("writable");
    fs::create_dir(&writable).expect("create writable ancestor");
    fs::set_permissions(&writable, Permissions::from_mode(0o777)).expect("make ancestor writable");
    let source = writable.join("companion-auth-token");
    fs::write(&source, "private-daemon-panel-token-0123456789").expect("write credential source");
    fs::set_permissions(&source, Permissions::from_mode(0o600))
        .expect("make credential source private");

    let error = companion_dry_run_args(&source)
        .execute(&AppContext)
        .expect_err("writable credential ancestor must be refused")
        .to_string();

    assert!(error.contains("ancestor"), "{error}");
    assert!(error.contains("0777"), "{error}");
}

#[test]
fn non_regular_companion_credential_sources_are_rejected() {
    let temp = tempdir().expect("temp dir");
    let target = temp.path().join("target");
    let source = temp.path().join("companion-auth-token");
    fs::write(&target, "private-daemon-panel-token-0123456789").expect("write symlink target");
    fs::set_permissions(&target, Permissions::from_mode(0o600))
        .expect("make symlink target private");
    symlink(&target, &source).expect("create credential source symlink");

    let error = validate_companion_credential_source_for_tests(&source)
        .expect_err("symlink credential source must be refused")
        .to_string();

    assert!(error.contains("not a regular file"), "{error}");
}

#[test]
fn invalid_companion_credential_contents_are_rejected() {
    for (name, contents, message) in [
        ("short", "short", "at least 32 bytes"),
        (
            "header-unsafe",
            "private daemon panel token 0123456789",
            "header-unsafe",
        ),
    ] {
        let temp = tempdir().expect("temp dir");
        let source = temp.path().join(name);
        fs::write(&source, contents).expect("write credential source");
        fs::set_permissions(&source, Permissions::from_mode(0o600))
            .expect("make credential source private");

        let error = validate_companion_credential_source_for_tests(&source)
            .expect_err("invalid credential contents must be refused")
            .to_string();

        assert!(error.contains(message), "{name}: {error}");
    }
}

#[test]
fn oversized_companion_credential_source_is_rejected() {
    let temp = tempdir().expect("temp dir");
    let source = temp.path().join("oversized");
    fs::write(&source, vec![b'A'; 64 * 1024 + 1]).expect("write oversized credential");
    fs::set_permissions(&source, Permissions::from_mode(0o600))
        .expect("make credential source private");

    let error = validate_companion_credential_source_for_tests(&source)
        .expect_err("oversized credential must be refused")
        .to_string();

    assert!(error.contains("maximum"), "{error}");
    assert!(error.contains("65536"), "{error}");
}

#[test]
fn companion_install_requires_systemd_247_before_writing_files() {
    let temp = tempdir().expect("temp dir");
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--companion-upstream",
        "http://127.0.0.1:8787",
        "--companion-auth-token-file",
        COMPANION_TOKEN_SOURCE,
    ]);
    let unit_path = temp.path().join("systemd/remote.service");
    let env_path = temp.path().join("harness/remote.env");
    let plan = RemoteSystemdInstallPlan::for_tests(
        &args,
        trusted_test_executable(temp.path()),
        unit_path.clone(),
        env_path.clone(),
    )
    .expect("companion install plan");
    let runner = |arguments: &[String]| {
        assert_eq!(arguments, ["show", "--property=Version"]);
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: "Version=246.99-test\n".to_string(),
            stderr: String::new(),
        })
    };

    let error = install_remote_systemd_with(&plan, &runner)
        .expect_err("old systemd must be rejected before installation")
        .to_string();

    assert!(error.contains("systemd 247"), "{error}");
    assert!(!unit_path.exists());
    assert!(!env_path.exists());
}

fn companion_dry_run_args(source: &Path) -> DaemonRemoteSystemdInstallArgs {
    install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--companion-upstream",
        "http://127.0.0.1:8787",
        "--companion-auth-token-file",
        source.to_str().expect("UTF-8 credential source"),
        "--binary-path",
        "/usr/local/bin/harness-daemon",
        "--dry-run",
    ])
}
