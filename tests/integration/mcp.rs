//! End-to-end MCP stdio server tests.

#[cfg(target_os = "macos")]
mod macos;

#[cfg(not(target_os = "macos"))]
#[test]
fn mcp_serve_non_macos_refuses_with_workflow_io_error() {
    use std::process::Command;

    use assert_cmd::cargo::cargo_bin;

    let output = Command::new(cargo_bin("harness-mcp"))
        .arg("serve")
        .output()
        .expect("run harness-mcp serve");
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("requires macOS"),
        "expected macOS refusal, got stderr: {stderr}",
    );
}
