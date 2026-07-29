use crate::daemon::protocol::{
    DaemonDiagnosticsReport, HarnessMonitorAuditEvent, HarnessMonitorAuditEventsResponse,
};
use crate::daemon::state::DaemonAuditEvent;

use super::remote_redaction::redact_known_secrets;

const REDACTED: &str = "[redacted]";

#[must_use]
pub(crate) fn project_diagnostics_report(
    mut report: DaemonDiagnosticsReport,
    viewer: bool,
) -> DaemonDiagnosticsReport {
    if !viewer {
        return report;
    }

    if let Some(manifest) = report.manifest.as_mut() {
        manifest.token_path = REDACTED.to_string();
        manifest.binary_stamp = None;
        manifest.host_bridge.socket_path = None;
        for capability in manifest.host_bridge.capabilities.values_mut() {
            capability.endpoint = None;
            capability.metadata.clear();
        }
    }

    report.launch_agent.path = REDACTED.to_string();
    report.launch_agent.domain_target = REDACTED.to_string();
    report.launch_agent.service_target = REDACTED.to_string();
    report.launch_agent.status_error = report
        .launch_agent
        .status_error
        .as_deref()
        .map(redact_known_secrets);

    report.workspace.daemon_root = REDACTED.to_string();
    report.workspace.manifest_path = REDACTED.to_string();
    report.workspace.auth_token_path = REDACTED.to_string();
    report.workspace.events_path = REDACTED.to_string();
    report.workspace.database_path = REDACTED.to_string();
    report.workspace.last_event = report.workspace.last_event.map(redact_daemon_event);
    report.recent_events = report
        .recent_events
        .into_iter()
        .map(redact_daemon_event)
        .collect();
    for probe in &mut report.acp_runtime_probe.probes {
        probe.install_hint = probe.install_hint.as_deref().map(redact_known_secrets);
    }

    report
}

#[must_use]
pub(crate) fn project_audit_events(
    mut response: HarnessMonitorAuditEventsResponse,
    viewer: bool,
) -> HarnessMonitorAuditEventsResponse {
    if viewer {
        response.events.iter_mut().for_each(redact_audit_event);
    }
    response
}

fn redact_daemon_event(mut event: DaemonAuditEvent) -> DaemonAuditEvent {
    event.message = redact_known_secrets(&event.message);
    event
}

fn redact_audit_event(event: &mut HarnessMonitorAuditEvent) {
    event.title = redact_known_secrets(&event.title);
    event.summary = redact_known_secrets(&event.summary);
    event.subject = event.subject.as_deref().map(redact_known_secrets);
    event.actor = event.actor.as_deref().map(redact_known_secrets);
    event.payload_json = None;
    event.legacy_message = event.legacy_message.as_deref().map(redact_known_secrets);
    event.related_urls.clear();
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use crate::agents::acp::probe::AcpRuntimeProbeResponse;
    use crate::daemon::launchd::LaunchAgentStatus;
    use crate::daemon::protocol::DaemonDiagnosticsReport;
    use crate::daemon::state::{
        DaemonBinaryStamp, DaemonDiagnostics, DaemonManifest, HostBridgeCapabilityManifest,
        HostBridgeManifest,
    };

    use super::project_diagnostics_report;

    #[test]
    fn viewer_diagnostics_remove_host_bridge_and_binary_identity() {
        let report = diagnostics_report();

        let projected = project_diagnostics_report(report, true);
        let manifest = projected.manifest.expect("viewer manifest");
        let capability = manifest
            .host_bridge
            .capabilities
            .get("codex")
            .expect("viewer capability");

        assert!(manifest.binary_stamp.is_none());
        assert!(manifest.host_bridge.socket_path.is_none());
        assert!(capability.endpoint.is_none());
        assert!(capability.metadata.is_empty());
    }

    #[test]
    fn full_diagnostics_projection_is_a_noop() {
        let report = diagnostics_report();
        let expected = serde_json::to_value(&report).expect("full diagnostics json");

        let projected = project_diagnostics_report(report, false);

        assert_eq!(
            serde_json::to_value(projected).expect("projected diagnostics json"),
            expected
        );
    }

    fn diagnostics_report() -> DaemonDiagnosticsReport {
        DaemonDiagnosticsReport {
            health: None,
            manifest: Some(DaemonManifest {
                version: "46.0.0".to_string(),
                pid: 42,
                endpoint: "https://daemon.example.com".to_string(),
                started_at: "2026-07-13T00:00:00Z".to_string(),
                token_path: "/private/token".to_string(),
                sandboxed: false,
                host_bridge: HostBridgeManifest {
                    running: true,
                    socket_path: Some("/private/bridge.sock".to_string()),
                    capabilities: BTreeMap::from([(
                        "codex".to_string(),
                        HostBridgeCapabilityManifest {
                            enabled: true,
                            healthy: true,
                            transport: "unix".to_string(),
                            endpoint: Some("/private/codex.sock".to_string()),
                            metadata: BTreeMap::from([(
                                "credential".to_string(),
                                "token=bridge-secret".to_string(),
                            )]),
                        },
                    )]),
                },
                revision: 1,
                updated_at: "2026-07-13T00:00:00Z".to_string(),
                binary_stamp: Some(DaemonBinaryStamp {
                    helper_path: "/private/helper".to_string(),
                    device_identifier: 1,
                    inode: 2,
                    file_size: 3,
                    modification_time_interval_since_1970: 4.0,
                }),
                ownership: Default::default(),
            }),
            launch_agent: LaunchAgentStatus {
                installed: false,
                loaded: false,
                label: "io.harness.daemon".to_string(),
                path: "/private/launch-agent".to_string(),
                domain_target: "gui/private".to_string(),
                service_target: "gui/private/io.harness.daemon".to_string(),
                state: None,
                pid: None,
                last_exit_status: None,
                status_error: None,
            },
            acp_runtime_probe: AcpRuntimeProbeResponse {
                probes: Vec::new(),
                checked_at: "2026-07-13T00:00:00Z".to_string(),
            },
            github_api: None,
            workspace: DaemonDiagnostics {
                daemon_root: "/private/root".to_string(),
                manifest_path: "/private/manifest".to_string(),
                auth_token_path: "/private/token".to_string(),
                auth_token_present: true,
                events_path: "/private/events".to_string(),
                database_path: "/private/database".to_string(),
                database_size_bytes: 1,
                last_event: None,
            },
            recent_events: Vec::new(),
        }
    }
}
