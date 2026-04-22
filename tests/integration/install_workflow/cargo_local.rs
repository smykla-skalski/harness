use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::tempdir;

use super::support::{parse_env_output, parse_output_lines, write_fake_shell_tool};

#[test]
fn cargo_local_script_falls_back_to_repo_local_tmpdir_when_tmpdir_is_missing() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/cargo-local.sh"))
        .arg("--print-env")
        .current_dir(&repo)
        .env("HOME", tmp.path().join("home"))
        .env_remove("TMPDIR")
        .env_remove("CODEX_SESSION_ID")
        .env_remove("CODEX_THREAD_ID")
        .env_remove("CLAUDE_SESSION_ID")
        .env_remove("GEMINI_SESSION_ID")
        .env_remove("COPILOT_SESSION_ID")
        .env_remove("OPENCODE_SESSION_ID")
        .output()
        .expect("run cargo-local script");

    assert!(
        output.status.success(),
        "script failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let env = parse_env_output(&output.stdout);
    let tmpdir = env.get("TMPDIR").expect("TMPDIR line");
    assert_eq!(
        tmpdir,
        &format!("{}/target/.cargo-local/tmp/local/", repo.display())
    );
    assert!(
        Path::new(tmpdir).is_dir(),
        "expected repo-local tmpdir to exist: {tmpdir}"
    );
}

#[test]
fn cargo_local_script_preserves_explicit_writable_tmpdir() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let explicit_tmpdir = tmp.path().join("explicit-tmp");
    std::fs::create_dir_all(&explicit_tmpdir).expect("create explicit tmpdir");

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/cargo-local.sh"))
        .arg("--print-env")
        .current_dir(&repo)
        .env("HOME", tmp.path().join("home"))
        .env("TMPDIR", &explicit_tmpdir)
        .env_remove("CODEX_SESSION_ID")
        .env_remove("CODEX_THREAD_ID")
        .env_remove("CLAUDE_SESSION_ID")
        .env_remove("GEMINI_SESSION_ID")
        .env_remove("COPILOT_SESSION_ID")
        .env_remove("OPENCODE_SESSION_ID")
        .output()
        .expect("run cargo-local script");

    assert!(
        output.status.success(),
        "script failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let env = parse_env_output(&output.stdout);
    assert_eq!(
        env.get("TMPDIR").expect("TMPDIR line"),
        &explicit_tmpdir.display().to_string()
    );
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
fn observability_script_test_helper_writes_shared_config_to_both_runtime_roots() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let daemon_home = tmp.path().join("daemon-data");
    let xdg_home = tmp.path().join("xdg-data");
    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--write-shared-config-fixture")
        .arg("true")
        .current_dir(&repo)
        .env("HOME", tmp.path().join("home"))
        .env("HARNESS_DAEMON_DATA_HOME", &daemon_home)
        .env("XDG_DATA_HOME", &xdg_home)
        .output()
        .expect("run observability script fixture writer");

    assert!(
        output.status.success(),
        "script failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let written_paths = parse_output_lines(&output.stdout);
    assert_eq!(
        written_paths,
        vec![
            daemon_home
                .join("harness/observability/config.json")
                .display()
                .to_string(),
            xdg_home
                .join("harness/observability/config.json")
                .display()
                .to_string(),
        ]
    );

    for path in written_paths {
        let body = std::fs::read_to_string(&path).expect("read shared config");
        assert!(
            body.contains("\"monitor_smoke_enabled\": true"),
            "expected monitor smoke flag in {path}: {body}"
        );
        assert!(
            body.contains("\"grpc_endpoint\": \"http://127.0.0.1:4317\""),
            "expected gRPC endpoint in {path}: {body}"
        );
    }
}

#[test]
fn cargo_local_script_prefers_rtk_for_supported_subcommands() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_bin = tmp.path().join("fake-bin");
    let log_path = tmp.path().join("fake-script.log");

    write_fake_shell_tool(
        &fake_bin.join("rtk"),
        "#!/bin/sh\nset -eu\nprintf 'RTK=%s\\n' \"$*\" >\"$FAKE_SCRIPT_LOG\"\n",
    );
    write_fake_shell_tool(
        &fake_bin.join("cargo"),
        "#!/bin/sh\nset -eu\nprintf 'CARGO=%s\\n' \"$*\" >\"$FAKE_SCRIPT_LOG\"\n",
    );

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/cargo-local.sh"))
        .arg("test")
        .arg("--lib")
        .current_dir(&repo)
        .env("FAKE_SCRIPT_LOG", &log_path)
        .env("HOME", tmp.path().join("home"))
        .env("PATH", format!("{}:/usr/bin:/bin", fake_bin.display()))
        .output()
        .expect("run cargo-local test wrapper");

    assert!(
        output.status.success(),
        "script failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let log = std::fs::read_to_string(&log_path).expect("read fake script log");
    assert_eq!(log.trim(), "RTK=cargo test --lib");
}

#[test]
fn cargo_local_script_keeps_run_subcommand_raw_when_rtk_is_available() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_bin = tmp.path().join("fake-bin");
    let log_path = tmp.path().join("fake-script.log");

    write_fake_shell_tool(
        &fake_bin.join("rtk"),
        "#!/bin/sh\nset -eu\nprintf 'RTK=%s\\n' \"$*\" >\"$FAKE_SCRIPT_LOG\"\n",
    );
    write_fake_shell_tool(
        &fake_bin.join("cargo"),
        "#!/bin/sh\nset -eu\nprintf 'CARGO=%s\\n' \"$*\" >\"$FAKE_SCRIPT_LOG\"\n",
    );

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/cargo-local.sh"))
        .arg("run")
        .arg("--quiet")
        .arg("--")
        .arg("daemon")
        .arg("serve")
        .current_dir(&repo)
        .env("FAKE_SCRIPT_LOG", &log_path)
        .env("HOME", tmp.path().join("home"))
        .env("PATH", format!("{}:/usr/bin:/bin", fake_bin.display()))
        .output()
        .expect("run cargo-local run wrapper");

    assert!(
        output.status.success(),
        "script failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let log = std::fs::read_to_string(&log_path).expect("read fake script log");
    assert_eq!(log.trim(), "CARGO=run --quiet -- daemon serve");
}
