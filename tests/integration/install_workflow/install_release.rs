use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;

use tempfile::tempdir;

use super::support::{run_harness_version, write_fake_harness_binary};

#[test]
fn install_script_reconciles_shadowed_harness_binary_for_stale_shell_paths() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let home = tmp.path().join("home");
    let install_dir = home.join(".local/bin");
    let shadow_dir = home.join("shadow/bin");
    let cargo_home = home.join(".cargo");
    let target_dir = tmp.path().join("cargo-target");
    let build_binary = target_dir.join("release/harness");
    let version = env!("CARGO_PKG_VERSION");
    std::fs::create_dir_all(&install_dir).expect("create install dir");
    write_fake_harness_binary(&build_binary, version);
    let shadow_binary = shadow_dir.join("harness");
    write_fake_harness_binary(&shadow_binary, "18.2.3");

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/install-harness-release.sh"))
        .current_dir(&repo)
        .env("HOME", &home)
        .env("CARGO_HOME", &cargo_home)
        .env("CARGO_TARGET_DIR", &target_dir)
        .env("HARNESS_INSTALL_SKIP_CODESIGN", "1")
        .env(
            "PATH",
            format!(
                "{}:{}:/usr/bin:/bin",
                shadow_dir.display(),
                install_dir.display()
            ),
        )
        .output()
        .expect("run install script");

    assert!(
        output.status.success(),
        "script failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        run_harness_version(&shadow_binary),
        format!("harness {version}"),
        "expected stale absolute shadow path to execute the installed harness"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("reconciled shadowed harness binary"),
        "expected shadow reconciliation message: {stderr}"
    );
    assert!(
        !stderr.contains("run `rehash` or start a new shell"),
        "expected no shell-refresh warning after reconciliation: {stderr}"
    );
}

#[test]
fn install_script_reconciles_shadowed_cargo_harness_binary_in_place() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let home = tmp.path().join("home");
    let install_dir = home.join(".local/bin");
    let cargo_home = home.join(".cargo");
    let cargo_dir = home.join(".cargo/bin");
    let target_dir = tmp.path().join("cargo-target");
    let build_binary = target_dir.join("release/harness");
    let cargo_binary = cargo_dir.join("harness");
    let version = env!("CARGO_PKG_VERSION");

    write_fake_harness_binary(&build_binary, version);
    write_fake_harness_binary(&cargo_binary, "18.2.3");

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/install-harness-release.sh"))
        .current_dir(&repo)
        .env("HOME", &home)
        .env("CARGO_HOME", &cargo_home)
        .env("CARGO_TARGET_DIR", &target_dir)
        .env("HARNESS_INSTALL_SKIP_CODESIGN", "1")
        .env(
            "PATH",
            format!(
                "{}:{}:/usr/bin:/bin",
                cargo_dir.display(),
                install_dir.display()
            ),
        )
        .output()
        .expect("run install script");

    assert!(
        output.status.success(),
        "script failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        cargo_binary.exists(),
        "expected cargo shadow binary path to keep existing for stale shell caches"
    );
    assert!(
        install_dir.join("harness").exists(),
        "expected install binary to exist"
    );
    assert_eq!(
        run_harness_version(&cargo_binary),
        format!("harness {version}"),
        "expected stale cargo absolute path to execute the installed harness"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("reconciled shadowed harness binary"),
        "expected cargo shadow reconciliation message: {stderr}"
    );
}

#[test]
fn install_script_fails_when_shadowed_harness_binary_cannot_be_reconciled() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let home = tmp.path().join("home");
    let install_dir = home.join(".local/bin");
    let shadow_dir = tmp.path().join("locked-shadow/bin");
    let target_dir = tmp.path().join("cargo-target");
    let build_binary = target_dir.join("release/harness");
    let shadow_binary = shadow_dir.join("harness");
    let version = env!("CARGO_PKG_VERSION");

    std::fs::create_dir_all(&install_dir).expect("create install dir");
    write_fake_harness_binary(&build_binary, version);
    write_fake_harness_binary(&shadow_binary, "18.2.3");
    std::fs::set_permissions(&shadow_dir, std::fs::Permissions::from_mode(0o555))
        .expect("lock shadow dir");

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/install-harness-release.sh"))
        .current_dir(&repo)
        .env("HOME", &home)
        .env("CARGO_TARGET_DIR", &target_dir)
        .env("HARNESS_INSTALL_SKIP_CODESIGN", "1")
        .env(
            "PATH",
            format!(
                "{}:{}:/usr/bin:/bin",
                shadow_dir.display(),
                install_dir.display()
            ),
        )
        .output()
        .expect("run install script");

    assert!(
        !output.status.success(),
        "expected install to fail: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("unable to reconcile shadowed harness binary"),
        "expected reconciliation failure message: {stderr}"
    );
}
