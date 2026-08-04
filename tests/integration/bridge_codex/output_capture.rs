use std::fs::File;

use super::*;

#[test]
fn bridge_does_not_capture_codex_routine_output() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let mock_codex = create_mock_codex(tmp.path());
    let codex_port_lease = TcpPortLease::acquire().expect("reserve codex port");
    let codex_port_text = codex_port_lease.port().to_string();
    let stdout_path = tmp.path().join("bridge.stdout.log");
    let stderr_path = tmp.path().join("bridge.stderr.log");

    let mut bridge = ManagedChild::spawn_with_port_lease(
        Command::new(bridge_binary())
            .args([
                "start",
                "--capability",
                "codex",
                "--codex-port",
                &codex_port_text,
                "--codex-path",
            ])
            .arg(&mock_codex)
            .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
            .env("XDG_DATA_HOME", tmp.path())
            .env("HARNESS_HOST_HOME", &host_home)
            .env_isolated_home(&host_home)
            .env("MOCK_CODEX_OUTPUT_BYTES", (256 * 1024).to_string())
            .env_remove("HARNESS_APP_GROUP_ID")
            .env_remove("HARNESS_SANDBOXED")
            .stdin(Stdio::null())
            .stdout(File::create(&stdout_path).expect("create bridge stdout capture"))
            .stderr(File::create(&stderr_path).expect("create bridge stderr capture")),
        codex_port_lease,
    )
    .expect("spawn bridge");

    wait_for_bridge_state_with_capabilities(tmp.path(), &["codex"]);
    let stop_output = run_bridge(&tmp, &["stop"]);
    assert!(
        stop_output.status.success(),
        "stop: {}",
        output_text(&stop_output)
    );
    wait_for_bridge_exit(&mut bridge);

    let stdout = std::fs::read_to_string(&stdout_path).expect("read bridge stdout capture");
    let stderr = std::fs::read_to_string(&stderr_path).expect("read bridge stderr capture");
    assert!(
        !stdout.contains("mock-codex-stdout"),
        "codex stdout leaked into bridge capture"
    );
    assert!(
        !stderr.contains("mock-codex-stderr"),
        "codex stderr leaked into bridge capture"
    );
}
