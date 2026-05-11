use super::*;

#[test]
fn default_permission_cap_matches_plan() {
    assert_eq!(DEFAULT_PERMISSION_CAP, 8);
}

#[test]
fn start_rejects_sandboxed_daemon_mode() {
    let Ok(sandbox) = TempDir::new() else {
        unreachable!();
    };
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                (feature_flags::ACP_ENV, Some("1")),
                ("HARNESS_SANDBOXED", Some("1")),
            ],
            || {
                let request = AcpAgentStartRequest {
                    agent: "copilot".to_string(),
                    ..AcpAgentStartRequest::default()
                };

                let Err(error) = manager().start("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc", &request)
                else {
                    unreachable!();
                };
                let rendered = format!("{error}");
                assert!(
                    rendered.contains("sandbox feature disabled: acp.host-bridge"),
                    "unexpected error: {rendered}"
                );
            },
        );
    });
}
