use crate::agents::acp::probe::{AcpAuthState, AcpRuntimeProbeResponse};
use crate::agents::runtime::models;
use crate::daemon::bridge::{
    BRIDGE_CAPABILITY_ACP, BRIDGE_CAPABILITY_AGENT_TUI, BRIDGE_CAPABILITY_CODEX, BridgeStatusReport,
};
use crate::daemon::protocol::{
    DAEMON_WIRE_VERSION, HeadlessReadinessCredential, HeadlessReadinessLane,
    HeadlessReadinessModel, HeadlessReadinessPeer, HeadlessReadinessReport,
    HeadlessReadinessRequest, HeadlessReadinessRuntime,
};

const LANES: [&str; 3] = [
    BRIDGE_CAPABILITY_CODEX,
    BRIDGE_CAPABILITY_ACP,
    BRIDGE_CAPABILITY_AGENT_TUI,
];

pub(crate) struct HeadlessReadinessInputs<'a> {
    pub request: &'a HeadlessReadinessRequest,
    pub daemon_version: &'a str,
    pub bridge: &'a BridgeStatusReport,
    pub runtime_probe: &'a AcpRuntimeProbeResponse,
    pub openrouter_configured: bool,
    pub orchestrator_active: bool,
}

#[expect(
    clippy::struct_excessive_bools,
    reason = "each field captures an independent prerequisite for reason collection"
)]
struct ReadinessEvaluation<'a> {
    selected_lane: &'a str,
    compatible: bool,
    lane_known: bool,
    lane_available: bool,
    credential_ready: bool,
    runtime_available: bool,
    model_available: bool,
}

pub(crate) fn build_headless_readiness_report(
    inputs: &HeadlessReadinessInputs<'_>,
) -> HeadlessReadinessReport {
    let selected_lane = inputs
        .request
        .lane
        .as_deref()
        .unwrap_or_else(|| default_lane(&inputs.request.runtime));
    let lanes = LANES
        .into_iter()
        .map(|lane| lane_status(inputs.bridge, lane))
        .collect::<Vec<_>>();
    let compatible = inputs.request.client_wire_version == DAEMON_WIRE_VERSION;
    let lane_available = lanes
        .iter()
        .any(|lane| lane.name == selected_lane && lane.available);
    let runtime_available = runtime_available(inputs, selected_lane, lane_available);
    let model_effective =
        models::effective_model(&inputs.request.runtime, Some(&inputs.request.model));
    let model_available =
        models::validate_model(&inputs.request.runtime, &inputs.request.model).is_ok();
    let credential = credential_status(inputs);
    let evaluation = ReadinessEvaluation {
        selected_lane,
        compatible,
        lane_known: LANES.contains(&selected_lane),
        lane_available,
        credential_ready: !credential.required || credential.configured == Some(true),
        runtime_available,
        model_available,
    };
    let unmet_requirements = collect_unmet_requirements(inputs, &evaluation, &credential);

    HeadlessReadinessReport {
        ready: unmet_requirements.is_empty(),
        client: HeadlessReadinessPeer {
            version: inputs.request.client_version.clone(),
            wire_version: inputs.request.client_wire_version,
        },
        daemon: HeadlessReadinessPeer {
            version: inputs.daemon_version.to_string(),
            wire_version: DAEMON_WIRE_VERSION,
        },
        compatible,
        bridge_reachable: inputs.bridge.running,
        lanes,
        selected_lane: selected_lane.to_string(),
        credential,
        runtime: HeadlessReadinessRuntime {
            requested: inputs.request.runtime.clone(),
            available: runtime_available,
        },
        model: HeadlessReadinessModel {
            requested: inputs.request.model.clone(),
            effective: model_effective,
            available: model_available,
        },
        orchestrator_active: inputs.orchestrator_active,
        unmet_requirements,
    }
}

fn collect_unmet_requirements(
    inputs: &HeadlessReadinessInputs<'_>,
    evaluation: &ReadinessEvaluation<'_>,
    credential: &HeadlessReadinessCredential,
) -> Vec<String> {
    let mut reasons = Vec::new();
    push_failure(
        &mut reasons,
        evaluation.compatible,
        format!(
            "client wire version {} is incompatible with daemon wire version {DAEMON_WIRE_VERSION}",
            inputs.request.client_wire_version
        ),
    );
    push_failure(
        &mut reasons,
        inputs.bridge.running,
        "host bridge is unreachable".to_string(),
    );
    push_failure(
        &mut reasons,
        evaluation.lane_known,
        format!("unknown execution lane '{}'", evaluation.selected_lane),
    );
    push_failure(
        &mut reasons,
        !evaluation.lane_known || evaluation.lane_available,
        format!(
            "execution lane '{}' is unavailable",
            evaluation.selected_lane
        ),
    );
    push_failure(
        &mut reasons,
        evaluation.credential_ready,
        format!(
            "{} credential is not configured",
            credential
                .provider
                .as_deref()
                .unwrap_or("required provider")
        ),
    );
    push_failure(
        &mut reasons,
        !evaluation.lane_known || evaluation.runtime_available,
        format!(
            "runtime '{}' is unavailable on lane '{}'",
            inputs.request.runtime, evaluation.selected_lane
        ),
    );
    push_failure(
        &mut reasons,
        evaluation.model_available,
        format!(
            "model '{}' is unavailable for runtime '{}'",
            inputs.request.model, inputs.request.runtime
        ),
    );
    push_failure(
        &mut reasons,
        inputs.orchestrator_active,
        "task-board orchestrator mode is not active".to_string(),
    );
    reasons
}

fn default_lane(runtime: &str) -> &'static str {
    if runtime == "codex" {
        BRIDGE_CAPABILITY_CODEX
    } else {
        BRIDGE_CAPABILITY_ACP
    }
}

fn lane_status(bridge: &BridgeStatusReport, lane: &str) -> HeadlessReadinessLane {
    let capability = bridge.capabilities.get(lane);
    let available = bridge.running
        && capability.is_some_and(|capability| capability.enabled && capability.healthy);
    let reason = if available {
        None
    } else if !bridge.running {
        Some("host bridge is not running".to_string())
    } else if capability.is_none() {
        Some("capability is not enabled".to_string())
    } else if capability.is_some_and(|capability| !capability.enabled) {
        Some("capability is disabled".to_string())
    } else {
        Some("capability is unhealthy".to_string())
    };
    HeadlessReadinessLane {
        name: lane.to_string(),
        available,
        reason,
    }
}

fn runtime_available(
    inputs: &HeadlessReadinessInputs<'_>,
    selected_lane: &str,
    lane_available: bool,
) -> bool {
    if !lane_available {
        return false;
    }
    match selected_lane {
        BRIDGE_CAPABILITY_CODEX => inputs.request.runtime == "codex",
        BRIDGE_CAPABILITY_ACP => inputs
            .runtime_probe
            .probes
            .iter()
            .find(|probe| probe.agent_id == inputs.request.runtime)
            .is_some_and(|probe| {
                probe.binary_present && probe.auth_state != AcpAuthState::Unavailable
            }),
        BRIDGE_CAPABILITY_AGENT_TUI => matches!(
            inputs.request.runtime.as_str(),
            "claude" | "codex" | "copilot" | "gemini" | "opencode" | "vibe"
        ),
        _ => false,
    }
}

fn credential_status(inputs: &HeadlessReadinessInputs<'_>) -> HeadlessReadinessCredential {
    if inputs.request.runtime == "openrouter" {
        HeadlessReadinessCredential {
            provider: Some("openrouter".to_string()),
            required: true,
            configured: Some(inputs.openrouter_configured),
        }
    } else {
        HeadlessReadinessCredential {
            provider: None,
            required: false,
            configured: None,
        }
    }
}

fn push_failure(reasons: &mut Vec<String>, passed: bool, reason: String) {
    if !passed {
        reasons.push(reason);
    }
}

#[cfg(test)]
mod tests {
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
            runtime_probe: &runtime_probe,
            openrouter_configured: true,
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
            runtime_probe: &runtime_probe,
            openrouter_configured: false,
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
            runtime_probe: &runtime_probe,
            openrouter_configured: false,
            orchestrator_active: true,
        });

        assert!(report.ready);
        assert_eq!(report.selected_lane, "codex");
        assert!(report.runtime.available);
        assert!(report.model.available);
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
            runtime_probe: &runtime_probe,
            openrouter_configured: false,
            orchestrator_active: true,
        });

        assert_eq!(
            report.unmet_requirements,
            vec!["unknown execution lane 'unknown'"]
        );
    }
}
