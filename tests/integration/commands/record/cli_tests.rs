#[test]
fn record_with_no_command_exits_nonzero() {
    harness_testkit::harness_cmd()
        .arg("record")
        .assert()
        .failure();
}
