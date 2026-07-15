use harness_daemon::feature_flags::RuntimeHookFlags;
use harness_daemon::hooks::adapters::HookAgent;

#[test]
fn daemon_setup_writes_the_real_agent_bootstrap_without_shelling_out() {
    let temporary = tempfile::tempdir().expect("temporary directory");
    let written = harness_daemon::setup::wrapper::write_agent_bootstrap(
        temporary.path(),
        HookAgent::Claude,
        &[],
        RuntimeHookFlags::all_enabled(),
    )
    .expect("write Claude bootstrap");
    let settings = temporary.path().join(".claude/settings.json");

    assert_eq!(written, vec![settings.clone()]);
    let contents = fs_err::read_to_string(settings).expect("read Claude settings");
    assert!(contents.contains("harness-hook session-start"));
    assert!(contents.contains("harness-hook guard-stop"));
}

#[test]
fn daemon_io_preserves_canonical_safety_and_permissions() {
    let unsafe_error = harness_daemon::infra::io::validate_safe_segment("safe..looking")
        .expect_err("embedded dot-dot is unsafe");
    assert_eq!(unsafe_error.code(), "KSRCLI059");

    let temporary = tempfile::tempdir().expect("temporary directory");
    let state = temporary.path().join("state.json");
    harness_daemon::infra::io::write_text(&state, "{}\n").expect("write state");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        assert_eq!(
            fs_err::metadata(state)
                .expect("state metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}
