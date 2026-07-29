use std::collections::BTreeMap;

use crate::daemon::state::HostBridgeCapabilityManifest;

use super::*;
use crate::agents::acp::probe::AcpRuntimeProbe;

fn ready_bridge() -> BridgeStatusReport {
    let capabilities = LANES
        .into_iter()
        .map(|lane| {
            (
                lane.to_string(),
                HostBridgeCapabilityManifest {
                    enabled: true,
                    healthy: true,
                    transport: "test".to_string(),
                    endpoint: Some("test".to_string()),
                    metadata: BTreeMap::new(),
                },
            )
        })
        .collect();
    BridgeStatusReport {
        running: true,
        socket_path: Some("test".to_string()),
        pid: Some(1),
        started_at: None,
        uptime_seconds: None,
        capabilities,
    }
}

fn probe(runtime: &str, available: bool) -> AcpRuntimeProbeResponse {
    AcpRuntimeProbeResponse {
        probes: vec![AcpRuntimeProbe {
            agent_id: runtime.to_string(),
            display_name: runtime.to_string(),
            binary_present: available,
            auth_state: if available {
                AcpAuthState::Unknown
            } else {
                AcpAuthState::Unavailable
            },
            version: None,
            install_hint: None,
        }],
        checked_at: "test".to_string(),
    }
}

fn request(runtime: &str, model: &str) -> HeadlessReadinessRequest {
    HeadlessReadinessRequest {
        client_version: "test".to_string(),
        client_wire_version: DAEMON_WIRE_VERSION,
        runtime: runtime.to_string(),
        model: model.to_string(),
        lane: None,
    }
}

#[test]
fn ready_openrouter_report_contains_no_credential_value() {
    let request = request("openrouter", "deepseek/deepseek-v4-flash");
    let bridge = ready_bridge();
    let runtime_probe = probe("openrouter", true);
    let report = build_headless_readiness_report(&HeadlessReadinessInputs {
        request: &request,
        daemon_version: "test",
        bridge: &bridge,
        runtime_probe: RuntimeProbe::Ready(&runtime_probe),
        credential: CredentialAssessment::Accepted,
        model_available: true,
        orchestrator_active: true,
    });

    assert!(report.ready);
    assert_eq!(report.selected_lane, "acp");
    assert_eq!(report.credential.provider.as_deref(), Some("openrouter"));
    assert_eq!(report.credential.configured, Some(true));
    assert!(report.unmet_requirements.is_empty());
    let json = serde_json::to_string(&report).expect("serialize report");
    assert!(!json.contains("api_key"));
    assert!(!json.contains("token"));
}

#[test]
fn unmet_requirements_are_accumulated_in_one_report() {
    let mut request = request("openrouter", "not-a-model");
    request.client_wire_version = DAEMON_WIRE_VERSION + 1;
    let bridge = BridgeStatusReport::not_running();
    let runtime_probe = probe("openrouter", false);
    let report = build_headless_readiness_report(&HeadlessReadinessInputs {
        request: &request,
        daemon_version: "test",
        bridge: &bridge,
        runtime_probe: RuntimeProbe::Ready(&runtime_probe),
        credential: CredentialAssessment::Missing,
        model_available: false,
        orchestrator_active: false,
    });

    assert!(!report.ready);
    for fragment in [
        "incompatible",
        "bridge is unreachable",
        "lane 'acp' is unavailable",
        "credential is not configured",
        "runtime 'openrouter' is unavailable",
        "model 'not-a-model' is unavailable",
        "orchestrator mode is not active",
    ] {
        assert!(
            report
                .unmet_requirements
                .iter()
                .any(|reason| reason.contains(fragment)),
            "missing reason containing '{fragment}'"
        );
    }
}

#[test]
fn codex_defaults_to_structured_codex_lane() {
    let request = request("codex", "gpt-5.4-mini");
    let bridge = ready_bridge();
    let runtime_probe = probe("codex", false);
    let report = build_headless_readiness_report(&HeadlessReadinessInputs {
        request: &request,
        daemon_version: "test",
        bridge: &bridge,
        runtime_probe: RuntimeProbe::Ready(&runtime_probe),
        credential: CredentialAssessment::NotRequired,
        model_available: true,
        orchestrator_active: true,
    });

    assert!(report.ready);
    assert_eq!(report.selected_lane, "codex");
    assert!(report.runtime.available);
    assert!(report.model.available);
    assert_eq!(report.credential.provider, None);
    assert!(!report.credential.required);
}

#[test]
fn disabled_lane_is_not_reported_as_unhealthy() {
    let mut bridge = ready_bridge();
    bridge
        .capabilities
        .get_mut(BRIDGE_CAPABILITY_ACP)
        .expect("ACP capability")
        .enabled = false;

    let status = lane_status(&bridge, BRIDGE_CAPABILITY_ACP);

    assert!(!status.available);
    assert_eq!(status.reason.as_deref(), Some("capability is disabled"));
}

#[test]
fn unknown_lane_does_not_cascade_into_unavailable_failures() {
    let mut request = request("codex", "gpt-5.4-mini");
    request.lane = Some("unknown".to_string());
    let bridge = ready_bridge();
    let runtime_probe = probe("codex", true);

    let report = build_headless_readiness_report(&HeadlessReadinessInputs {
        request: &request,
        daemon_version: "test",
        bridge: &bridge,
        runtime_probe: RuntimeProbe::Ready(&runtime_probe),
        credential: CredentialAssessment::NotRequired,
        model_available: true,
        orchestrator_active: true,
    });

    assert_eq!(
        report.unmet_requirements,
        vec!["unknown execution lane 'unknown'"]
    );
}

#[test]
fn pending_probe_reports_probe_incomplete_not_a_false_negative() {
    let request = request("openrouter", "deepseek/deepseek-v4-flash");
    let bridge = ready_bridge();
    let report = build_headless_readiness_report(&HeadlessReadinessInputs {
        request: &request,
        daemon_version: "test",
        bridge: &bridge,
        runtime_probe: RuntimeProbe::Pending,
        credential: CredentialAssessment::Accepted,
        model_available: true,
        orchestrator_active: true,
    });

    assert!(!report.ready);
    assert!(!report.runtime.available);
    assert!(
        report
            .unmet_requirements
            .iter()
            .any(|reason| reason.contains("probe for lane 'acp' has not completed")),
        "expected a probe-incomplete reason, got {:?}",
        report.unmet_requirements
    );
    assert!(
        !report
            .unmet_requirements
            .iter()
            .any(|reason| reason.contains("runtime 'openrouter' is unavailable")),
        "a pending probe must not read as a definitive runtime-unavailable failure"
    );
}

#[test]
fn rejected_credential_blocks_with_named_reason_and_no_secret() {
    let request = request("openrouter", "deepseek/deepseek-v4-flash");
    let bridge = ready_bridge();
    let runtime_probe = probe("openrouter", true);
    let report = build_headless_readiness_report(&HeadlessReadinessInputs {
        request: &request,
        daemon_version: "test",
        bridge: &bridge,
        runtime_probe: RuntimeProbe::Ready(&runtime_probe),
        credential: CredentialAssessment::Rejected("HTTP 401 Unauthorized".to_string()),
        model_available: true,
        orchestrator_active: true,
    });

    assert!(!report.ready);
    assert_eq!(report.credential.configured, Some(false));
    assert!(
        report
            .unmet_requirements
            .iter()
            .any(|reason| reason.contains("openrouter credential was rejected by the provider")),
        "expected a named credential-rejected reason, got {:?}",
        report.unmet_requirements
    );
    let json = serde_json::to_string(&report).expect("serialize report");
    assert!(!json.contains("sk-"));
}

#[test]
fn unverified_credential_is_named_distinctly_from_rejection() {
    let request = request("openrouter", "deepseek/deepseek-v4-flash");
    let bridge = ready_bridge();
    let runtime_probe = probe("openrouter", true);
    let report = build_headless_readiness_report(&HeadlessReadinessInputs {
        request: &request,
        daemon_version: "test",
        bridge: &bridge,
        runtime_probe: RuntimeProbe::Ready(&runtime_probe),
        credential: CredentialAssessment::Unverified("could not connect".to_string()),
        model_available: true,
        orchestrator_active: true,
    });

    assert!(!report.ready);
    assert_eq!(report.credential.configured, Some(false));
    assert!(
        report
            .unmet_requirements
            .iter()
            .any(|reason| reason.contains("could not be verified with the provider")),
        "expected a distinct could-not-verify reason, got {:?}",
        report.unmet_requirements
    );
}

#[test]
fn catalogued_but_live_unavailable_model_is_rejected() {
    let request = request("openrouter", "deepseek/deepseek-v4-flash");
    let bridge = ready_bridge();
    let runtime_probe = probe("openrouter", true);
    let report = build_headless_readiness_report(&HeadlessReadinessInputs {
        request: &request,
        daemon_version: "test",
        bridge: &bridge,
        runtime_probe: RuntimeProbe::Ready(&runtime_probe),
        credential: CredentialAssessment::Accepted,
        model_available: false,
        orchestrator_active: true,
    });

    assert!(!report.ready);
    assert!(!report.model.available);
    assert!(
        report
            .unmet_requirements
            .iter()
            .any(|reason| reason
                .contains("model 'deepseek/deepseek-v4-flash' is unavailable for runtime")),
        "expected a live model-unavailable reason, got {:?}",
        report.unmet_requirements
    );
    assert!(
        !report
            .unmet_requirements
            .iter()
            .any(|reason| reason.contains("credential")),
        "an accepted credential must not add a credential failure"
    );
}
