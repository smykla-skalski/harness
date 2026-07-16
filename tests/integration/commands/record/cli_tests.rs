#[test]
fn record_with_no_command_exits_nonzero() {
    assert_cmd::Command::cargo_bin("harness")
        .expect("harness binary")
        .arg("record")
        .assert()
        .failure();
}
