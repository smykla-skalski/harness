use std::process::Command;

#[test]
fn probe_prints_exact_adapter_identity() {
    let output = Command::new(env!("CARGO_BIN_EXE_harness-codex-acp"))
        .arg("--probe")
        .output()
        .expect("run adapter probe");

    assert!(output.status.success(), "probe exited with {}", output.status);
    assert_eq!(output.stdout, b"harness-codex-acp\n");
    assert!(output.stderr.is_empty());
}
