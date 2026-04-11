use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;

use tempfile::tempdir;

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
fn install_script_warns_when_path_contains_a_shadowed_harness_binary() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let home = tmp.path().join("home");
    let install_dir = home.join(".local/bin");
    let shadow_dir = home.join(".cargo/bin");
    let target_dir = tmp.path().join("cargo-target");
    let build_binary = target_dir.join("release/harness");
    let version = env!("CARGO_PKG_VERSION");
    std::fs::create_dir_all(build_binary.parent().expect("build binary parent"))
        .expect("create target dir");
    std::fs::create_dir_all(&shadow_dir).expect("create shadow dir");
    std::fs::create_dir_all(&install_dir).expect("create install dir");
    std::fs::write(
        &build_binary,
        format!(
            "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  echo 'harness {version}'\n  exit 0\nfi\nexit 0\n"
        ),
    )
    .expect("write fake build binary");
    std::fs::set_permissions(&build_binary, std::fs::Permissions::from_mode(0o755))
        .expect("chmod fake build binary");
    let shadow_binary = shadow_dir.join("harness");
    std::fs::write(
        &shadow_binary,
        "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  echo 'harness 18.2.3'\n  exit 0\nfi\nexit 0\n",
    )
    .expect("write shadow harness");
    std::fs::set_permissions(&shadow_binary, std::fs::Permissions::from_mode(0o755))
        .expect("chmod shadow harness");

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
        output.status.success(),
        "script failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("PATH also contains"),
        "expected shadowed path warning: {stderr}"
    );
    assert!(
        stderr.contains("run `rehash` or start a new shell"),
        "expected shell refresh guidance: {stderr}"
    );
}
