use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::tempdir;

fn write_fake_harness_binary(path: &Path, version: &str) {
    std::fs::create_dir_all(path.parent().expect("binary parent")).expect("create binary dir");
    std::fs::write(
        path,
        format!(
            "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  echo 'harness {version}'\n  exit 0\nfi\nif [ \"$1\" = \"--help\" ]; then\n  echo 'Harness CLI'\n  exit 0\nfi\nexit 0\n"
        ),
    )
    .expect("write fake harness");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
        .expect("chmod fake harness");
}

fn run_harness_version(path: &Path) -> String {
    let output = Command::new(path)
        .arg("--version")
        .output()
        .expect("run harness --version");
    assert!(
        output.status.success(),
        "version command failed for {}: stdout={} stderr={}",
        path.display(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

#[test]
fn install_script_resolves_build_binary_from_cargo_local_target_dir() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let expected_target = tmp.path().join("cargo-target");

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/install-harness-release.sh"))
        .arg("--print-build-binary")
        .current_dir(&repo)
        .env("HOME", tmp.path().join("home"))
        .env("HARNESS_CARGO_TARGET_DIR", &expected_target)
        .env_remove("CARGO_TARGET_DIR")
        .env_remove("CODEX_SESSION_ID")
        .env_remove("CODEX_THREAD_ID")
        .env_remove("CLAUDE_SESSION_ID")
        .env_remove("GEMINI_SESSION_ID")
        .env_remove("COPILOT_SESSION_ID")
        .env_remove("OPENCODE_SESSION_ID")
        .output()
        .expect("run install script");

    assert!(
        output.status.success(),
        "script failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        expected_target
            .join("release/harness")
            .display()
            .to_string()
    );
}

#[test]
fn install_script_prefers_explicit_cargo_target_dir_when_present() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let explicit_target = tmp.path().join("explicit-target");
    let fallback_target = tmp.path().join("fallback-target");

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/install-harness-release.sh"))
        .arg("--print-build-binary")
        .current_dir(&repo)
        .env("HOME", tmp.path().join("home"))
        .env("CARGO_TARGET_DIR", &explicit_target)
        .env("HARNESS_CARGO_TARGET_DIR", &fallback_target)
        .output()
        .expect("run install script");

    assert!(
        output.status.success(),
        "script failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        explicit_target
            .join("release/harness")
            .display()
            .to_string()
    );
}

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
