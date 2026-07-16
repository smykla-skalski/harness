#![cfg(unix)]

use std::env;
use std::fs;
use std::os::unix::fs::symlink;
use std::process::Command;

use harness_command::{WORKER_DIR_ENV, resolve_worker};

const CHILD_OUTPUT_ENV: &str = "HARNESS_COMMAND_SYMLINK_TEST_OUTPUT";
const WORKER_NAME: &str = "harness-daemon";

#[test]
fn invoking_through_shadow_symlink_resolves_release_worker() {
    let temporary = tempfile::tempdir().expect("temporary directory");
    let release_directory = temporary.path().join("release/bin");
    let shadow_directory = temporary.path().join("shadow");
    fs::create_dir_all(&release_directory).expect("create release directory");
    fs::create_dir_all(&shadow_directory).expect("create shadow directory");

    let release_executable = release_directory.join("harness");
    fs::copy(
        env::current_exe().expect("current test executable"),
        &release_executable,
    )
    .expect("copy test executable");
    let release_worker = release_directory.join(WORKER_NAME);
    fs::write(&release_worker, "worker").expect("write release worker");

    let shadow_executable = shadow_directory.join("harness");
    symlink(&release_executable, &shadow_executable).expect("link shadow executable");
    let child_output = temporary.path().join("resolved-worker");
    let output = Command::new(&shadow_executable)
        .args(["--exact", "symlink_child_reports_worker"])
        .env(CHILD_OUTPUT_ENV, &child_output)
        .env_remove(WORKER_DIR_ENV)
        .output()
        .expect("invoke shadow executable");

    assert!(
        output.status.success(),
        "shadow invocation failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let resolved = fs::read_to_string(child_output).expect("read child resolution");
    assert_eq!(
        resolved,
        release_worker
            .canonicalize()
            .expect("canonical release worker")
            .to_string_lossy()
    );
}

#[test]
fn symlink_child_reports_worker() {
    let Some(output_path) = env::var_os(CHILD_OUTPUT_ENV) else {
        return;
    };
    let worker = resolve_worker(WORKER_NAME, env!("CARGO_PKG_VERSION"))
        .expect("resolve worker from symlink invocation");
    fs::write(output_path, worker.to_string_lossy().as_bytes()).expect("write resolved worker");
}
