use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::tempdir;

use super::support::{parse_env_output, write_fake_shell_tool};

#[test]
fn cargo_local_script_uses_short_external_tmpdir_when_tmpdir_is_missing() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let missing_sccache = tmp.path().join("missing-sccache");
    let session_id = format!("cargo-local-missing-tmpdir-{}", std::process::id());

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/cargo-local.sh"))
        .arg("--print-env")
        .current_dir(&repo)
        .env("HOME", tmp.path().join("home"))
        .env("SCCACHE_BIN", &missing_sccache)
        .env_remove("TMPDIR")
        .env("CODEX_SESSION_ID", session_id)
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
    let common_repo_root = resolve_common_repo_root(&repo);
    let fallback = Path::new(tmpdir.trim_end_matches('/'));
    assert!(
        tmpdir.starts_with("/tmp/harness-cargo-") && tmpdir.ends_with('/'),
        "expected short external TMPDIR, got {tmpdir}"
    );
    assert!(
        tmpdir.len() < 64,
        "external TMPDIR should remain short: {tmpdir}"
    );
    assert!(
        !fallback.starts_with(&repo) && !fallback.starts_with(&common_repo_root),
        "fallback must stay outside checkout and common repo: {tmpdir}"
    );
    assert!(
        fallback.is_dir(),
        "expected external tmpdir to exist: {tmpdir}"
    );

    std::fs::remove_dir(fallback).expect("remove external tmpdir");
}

fn resolve_common_repo_root(repo: &Path) -> PathBuf {
    let Ok(output) = Command::new("git")
        .arg("-C")
        .arg(repo)
        .arg("rev-parse")
        .arg("--path-format=absolute")
        .arg("--git-common-dir")
        .output()
    else {
        return repo.to_path_buf();
    };
    if !output.status.success() {
        return repo.to_path_buf();
    }
    let common_git_dir = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if common_git_dir.is_empty() {
        return repo.to_path_buf();
    }
    Path::new(&common_git_dir)
        .parent()
        .map_or_else(|| repo.to_path_buf(), Path::to_path_buf)
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
fn cargo_local_script_uses_short_external_tmpdir_when_tmpdir_is_unusable() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let unusable_tmpdir = tmp.path().join("not-a-directory");
    let missing_sccache = tmp.path().join("missing-sccache");
    let session_id = format!("cargo-local-unusable-tmpdir-{}", std::process::id());
    std::fs::write(&unusable_tmpdir, "not a directory").expect("write unusable TMPDIR");

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/cargo-local.sh"))
        .arg("--print-env")
        .current_dir(&repo)
        .env("HOME", tmp.path().join("home"))
        .env("SCCACHE_BIN", &missing_sccache)
        .env("TMPDIR", &unusable_tmpdir)
        .env("CODEX_SESSION_ID", session_id)
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
    let fallback = Path::new(tmpdir.trim_end_matches('/'));
    assert!(
        tmpdir.starts_with("/tmp/harness-cargo-") && tmpdir.ends_with('/'),
        "expected short external TMPDIR, got {tmpdir}"
    );
    assert!(
        tmpdir.len() < 64,
        "external TMPDIR should remain short: {tmpdir}"
    );
    assert!(
        fallback.is_dir(),
        "expected external tmpdir to exist: {tmpdir}"
    );

    std::fs::remove_dir(fallback).expect("remove external tmpdir");
}

#[test]
fn cargo_local_script_isolates_sccache_server_socket() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let explicit_tmpdir = tmp.path().join("explicit-tmp");
    let fake_bin = tmp.path().join("fake-bin");
    std::fs::create_dir_all(&explicit_tmpdir).expect("create explicit tmpdir");

    write_fake_shell_tool(
        &fake_bin.join("sccache"),
        "#!/bin/sh\nset -eu\nif [ \"$1\" = \"--version\" ]; then\n  echo 'sccache 0.16.0'\n  exit 0\nfi\nexit 1\n",
    );

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/cargo-local.sh"))
        .arg("--print-env")
        .current_dir(&repo)
        .env("HOME", tmp.path().join("home"))
        .env("PATH", format!("{}:/usr/bin:/bin", fake_bin.display()))
        .env("TMPDIR", &explicit_tmpdir)
        .env_remove("RUSTC_WRAPPER")
        .env_remove("SCCACHE_SERVER_UDS")
        .env_remove("SCCACHE_SERVER_PORT")
        .env_remove("SCCACHE_NO_DAEMON")
        .env_remove("SCCACHE_BASEDIRS")
        .env_remove("SCCACHE_IDLE_TIMEOUT")
        .env_remove("SCCACHE_CACHE_SIZE")
        .env_remove("SCCACHE_BIN")
        .env_remove("SCCACHE_VERSION")
        .env_remove("HARNESS_SCCACHE_TMPDIR")
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
    let socket = env
        .get("SCCACHE_SERVER_UDS")
        .expect("SCCACHE_SERVER_UDS line");
    assert!(
        socket.contains("/harness-sccache"),
        "unexpected socket path: {socket}"
    );
    assert!(
        socket.ends_with(".sock"),
        "unexpected socket path: {socket}"
    );
    assert!(
        socket.len() < 104,
        "sccache Unix socket path should stay below macOS sockaddr_un limits: {socket}"
    );
    assert!(
        Path::new(socket).parent().expect("socket parent").is_dir(),
        "expected socket parent to exist: {socket}"
    );
    assert_eq!(
        env.get("SCCACHE_BIN").expect("SCCACHE_BIN line"),
        &fake_bin.join("sccache").display().to_string()
    );
    assert_eq!(
        env.get("SCCACHE_VERSION").expect("SCCACHE_VERSION line"),
        "0.16.0"
    );
    assert_eq!(env.get("RUSTC_WRAPPER").expect("RUSTC_WRAPPER line"), "");
    assert_eq!(env.get("CACHE_MODE").expect("CACHE_MODE line"), "sccache");
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
    let expected_target = expected_target
        .canonicalize()
        .expect("canonicalize cargo-local target dir");
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
    let explicit_target = explicit_target
        .canonicalize()
        .expect("canonicalize explicit target dir");
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        explicit_target
            .join("release/harness")
            .display()
            .to_string()
    );
}

#[test]
fn cargo_local_script_uses_cargo_for_supported_subcommands() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_bin = tmp.path().join("fake-bin");
    let log_path = tmp.path().join("fake-script.log");

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
    assert_eq!(log.trim(), "CARGO=test --lib");
}

#[test]
fn cargo_local_script_uses_cargo_for_run_subcommand() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_bin = tmp.path().join("fake-bin");
    let log_path = tmp.path().join("fake-script.log");

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

#[test]
fn cargo_local_script_uses_cargo_for_fmt_subcommand() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_bin = tmp.path().join("fake-bin");
    let log_path = tmp.path().join("fake-script.log");

    write_fake_shell_tool(
        &fake_bin.join("cargo"),
        "#!/bin/sh\nset -eu\nprintf 'CARGO=%s\\n' \"$*\" >\"$FAKE_SCRIPT_LOG\"\n",
    );

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/cargo-local.sh"))
        .arg("fmt")
        .current_dir(&repo)
        .env("FAKE_SCRIPT_LOG", &log_path)
        .env("HOME", tmp.path().join("home"))
        .env("PATH", format!("{}:/usr/bin:/bin", fake_bin.display()))
        .output()
        .expect("run cargo-local fmt wrapper");

    assert!(
        output.status.success(),
        "script failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let log = std::fs::read_to_string(&log_path).expect("read fake script log");
    assert_eq!(log.trim(), "CARGO=fmt");
}
