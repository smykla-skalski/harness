use crate::agents::acp::probe::{AcpAuthState, AcpRuntimeProbeResponse};
use crate::agents::runtime::models;
use crate::daemon::bridge::{
    BRIDGE_CAPABILITY_ACP, BRIDGE_CAPABILITY_AGENT_TUI, BRIDGE_CAPABILITY_CODEX, BridgeStatusReport,
};
use harness_protocol::daemon::{
    DAEMON_WIRE_VERSION, HeadlessReadinessCredential, HeadlessReadinessLane,
    HeadlessReadinessModel, HeadlessReadinessPeer, HeadlessReadinessReport,
    HeadlessReadinessRequest, HeadlessReadinessRuntime,
};

const LANES: [&str; 3] = [
    BRIDGE_CAPABILITY_CODEX,
    BRIDGE_CAPABILITY_ACP,
    BRIDGE_CAPABILITY_AGENT_TUI,
];

/// Outcome of consulting the ACP runtime probe on the readiness path.
///
/// `Pending` means the process-local probe cache has not produced a result
/// yet (cold cache or an in-flight refresh). The distinction matters because a
/// pending probe must not be reported as a definitive "runtime unavailable":
/// that transient false negative is what this type exists to prevent.
pub(crate) enum RuntimeProbe<'a> {
    Ready(&'a AcpRuntimeProbeResponse),
    Pending,
}

/// Authoritative provider-credential assessment for the requested runtime.
///
/// The provider is asked whether the configured credential is accepted, rather
/// than trusting mere presence. `Rejected` and `Unverified` carry a redacted
/// detail (an HTTP status or transport reason) that never contains the secret.
pub(crate) enum CredentialAssessment {
    /// The runtime needs no provider credential.
    NotRequired,
    /// A credential is required but none is configured.
    Missing,
    /// A configured credential was rejected by the provider.
    Rejected(String),
    /// The provider could not be reached to validate the credential.
    Unverified(String),
    /// The provider accepted the configured credential.
    Accepted,
}

pub(crate) struct HeadlessReadinessInputs<'a> {
    pub request: &'a HeadlessReadinessRequest,
    pub daemon_version: &'a str,
    pub bridge: &'a BridgeStatusReport,
    pub runtime_probe: RuntimeProbe<'a>,
    pub credential: CredentialAssessment,
    pub model_available: bool,
    pub orchestrator_active: bool,
}

enum RuntimeOutcome {
    Available,
    Unavailable,
    ProbePending,
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
    runtime_outcome: RuntimeOutcome,
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
    let runtime_outcome = runtime_outcome(inputs, selected_lane, lane_available);
    let runtime_available = matches!(runtime_outcome, RuntimeOutcome::Available);
    let model_effective =
        models::effective_model(&inputs.request.runtime, Some(&inputs.request.model));
    let credential = credential_report(&inputs.credential, &inputs.request.runtime);
    let evaluation = ReadinessEvaluation {
        selected_lane,
        compatible,
        lane_known: LANES.contains(&selected_lane),
        lane_available,
        runtime_outcome,
        model_available: inputs.model_available,
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
            available: inputs.model_available,
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
    push_credential_failure(&mut reasons, &inputs.credential, credential);
    push_runtime_failure(&mut reasons, inputs, evaluation);
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

fn push_credential_failure(
    reasons: &mut Vec<String>,
    assessment: &CredentialAssessment,
    credential: &HeadlessReadinessCredential,
) {
    let provider = credential
        .provider
        .as_deref()
        .unwrap_or("required provider");
    match assessment {
        CredentialAssessment::NotRequired | CredentialAssessment::Accepted => {}
        CredentialAssessment::Missing => {
            reasons.push(format!("{provider} credential is not configured"));
        }
        CredentialAssessment::Rejected(detail) => {
            reasons.push(format!(
                "{provider} credential was rejected by the provider ({detail})"
            ));
        }
        CredentialAssessment::Unverified(detail) => {
            reasons.push(format!(
                "{provider} credential could not be verified with the provider ({detail})"
            ));
        }
    }
}

fn push_runtime_failure(
    reasons: &mut Vec<String>,
    inputs: &HeadlessReadinessInputs<'_>,
    evaluation: &ReadinessEvaluation<'_>,
) {
    if !evaluation.lane_known {
        return;
    }
    match evaluation.runtime_outcome {
        RuntimeOutcome::Available => {}
        RuntimeOutcome::Unavailable => reasons.push(format!(
            "runtime '{}' is unavailable on lane '{}'",
            inputs.request.runtime, evaluation.selected_lane
        )),
        RuntimeOutcome::ProbePending => reasons.push(format!(
            "runtime probe for lane '{}' has not completed; readiness is unknown",
            evaluation.selected_lane
        )),
    }
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

fn runtime_outcome(
    inputs: &HeadlessReadinessInputs<'_>,
    selected_lane: &str,
    lane_available: bool,
) -> RuntimeOutcome {
    if !lane_available {
        return RuntimeOutcome::Unavailable;
    }
    match selected_lane {
        BRIDGE_CAPABILITY_CODEX => bool_outcome(inputs.request.runtime == "codex"),
        BRIDGE_CAPABILITY_ACP => match &inputs.runtime_probe {
            RuntimeProbe::Pending => RuntimeOutcome::ProbePending,
            RuntimeProbe::Ready(probe) => bool_outcome(
                probe
                    .probes
                    .iter()
                    .find(|probe| probe.agent_id == inputs.request.runtime)
                    .is_some_and(|probe| {
                        probe.binary_present && probe.auth_state != AcpAuthState::Unavailable
                    }),
            ),
        },
        BRIDGE_CAPABILITY_AGENT_TUI => bool_outcome(matches!(
            inputs.request.runtime.as_str(),
            "claude" | "codex" | "copilot" | "gemini" | "opencode" | "vibe"
        )),
        _ => RuntimeOutcome::Unavailable,
    }
}

fn bool_outcome(available: bool) -> RuntimeOutcome {
    if available {
        RuntimeOutcome::Available
    } else {
        RuntimeOutcome::Unavailable
    }
}

fn credential_report(
    assessment: &CredentialAssessment,
    runtime: &str,
) -> HeadlessReadinessCredential {
    match assessment {
        CredentialAssessment::NotRequired => HeadlessReadinessCredential {
            provider: None,
            required: false,
            configured: None,
        },
        CredentialAssessment::Accepted => HeadlessReadinessCredential {
            provider: credential_provider(runtime).map(str::to_string),
            required: true,
            configured: Some(true),
        },
        CredentialAssessment::Missing
        | CredentialAssessment::Rejected(_)
        | CredentialAssessment::Unverified(_) => HeadlessReadinessCredential {
            provider: credential_provider(runtime).map(str::to_string),
            required: true,
            configured: Some(false),
        },
    }
}

fn credential_provider(runtime: &str) -> Option<&'static str> {
    (runtime == "openrouter").then_some("openrouter")
}

fn push_failure(reasons: &mut Vec<String>, passed: bool, reason: String) {
    if !passed {
        reasons.push(reason);
    }
}

#[cfg(test)]
#[path = "headless_readiness_tests.rs"]
mod tests;
