use super::*;
use crate::daemon::agent_acp::sandbox_proxy::logging::inspect_failure_warning_is_due;
use harness_telemetry::RepeatedLogGate;

#[test]
fn repeated_missing_bridge_inspection_is_rate_limited() {
    let unavailable = CliError::from(CliErrorKind::sandbox_feature_disabled("acp.host-bridge"));
    let mut gate = RepeatedLogGate::default();

    assert!(inspect_failure_warning_is_due(
        &mut gate,
        &unavailable,
        "failed to connect to ACP host bridge"
    ));
    assert!(!inspect_failure_warning_is_due(
        &mut gate,
        &unavailable,
        "failed to connect to ACP host bridge"
    ));
}
