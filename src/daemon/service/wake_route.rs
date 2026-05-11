// TRIPWIRE TODO:
//   - If a third `ManagedAgentKind` lands, prefer extending the kind enum +
//     a third arm here over adding a fourth `WakeRoute` variant.
//   - If this file ever passes ~350 lines or grows non-routing logic, fold it
//     back into signals.rs and split signals.rs along the ack-poll seam.
//   - If anything outside tracing branches on `NoneReason` (per-reason
//     metrics, recovery path), promote `Display` consumers to programmatic
//     pattern-matching at that moment.

use std::borrow::Cow;
use std::fmt;

use super::signals::managed_tui_id_for_registration;
use super::{AcpAgentManagerHandle, AgentRegistration, AgentTuiManagerHandle, session_service};
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::state::append_event_best_effort;
use crate::session::types::{ManagedAgentKind, ManagedAgentRef};

/// Severity of a single ACP wake-decision telemetry record.
#[derive(Clone, Copy)]
pub(crate) enum WakeEventLevel {
    Info,
    Warn,
    Error,
}

impl WakeEventLevel {
    fn as_str(self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Warn => "warn",
            Self::Error => "error",
        }
    }
}

/// Single source-of-truth for ACP wake-decision telemetry. Fans the same
/// payload into both observation pipelines so the line operators grep in
/// `events.jsonl` matches what `tracing` emits for unified-log queries:
///
///   - `tracing::{info,warn,error}!` at `target = "harness::wake"` with a
///     structured `kind` field and the rendered `acp_wake.<kind> k=v ...`
///     message.
///   - `append_event_best_effort(level, message)` to `events.jsonl` so the
///     diagnostics surface and any downstream regex consumer see the same
///     string.
///
/// Co-locating formatting here keeps the seven wake call sites from drifting
/// against each other, and reduces a future migration (typed
/// `DaemonAuditEvent::AcpWake { kind, fields }` enum) to a one-file change.
///
/// TRIPWIRE: if a second programmatic consumer parses these strings
/// (per-reason metrics, alerting, dashboards), promote `DaemonAuditEvent`
/// to a typed enum so the schema is enforced by the compiler instead of
/// by greppers.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(crate) fn record_wake_event(
    level: WakeEventLevel,
    kind: &'static str,
    fields: &[(&'static str, &dyn fmt::Display)],
) {
    use std::fmt::Write as _;
    let mut message = format!("acp_wake.{kind}");
    for (key, value) in fields {
        let _ = write!(message, " {key}={value}");
    }
    match level {
        WakeEventLevel::Info => {
            tracing::info!(target: "harness::wake", kind, %message);
        }
        WakeEventLevel::Warn => {
            tracing::warn!(target: "harness::wake", kind, %message);
        }
        WakeEventLevel::Error => {
            tracing::error!(target: "harness::wake", kind, %message);
        }
    }
    append_event_best_effort(level.as_str(), &message);
}

/// Bundle of managed-agent transport handles. Threading `WakeDispatch`
/// through mutation entry points keeps the call signatures stable when a
/// new managed-agent kind lands; the only churn is one new field on this
/// struct, not 8+ call sites.
#[derive(Clone, Copy)]
pub struct WakeDispatch<'a> {
    pub agent_tui: Option<&'a AgentTuiManagerHandle>,
    pub acp_agent: Option<&'a AcpAgentManagerHandle>,
    pub codex: Option<&'a CodexControllerHandle>,
}

impl<'a> WakeDispatch<'a> {
    #[must_use]
    pub fn new(
        agent_tui: Option<&'a AgentTuiManagerHandle>,
        acp_agent: Option<&'a AcpAgentManagerHandle>,
    ) -> Self {
        Self {
            agent_tui,
            acp_agent,
            codex: None,
        }
    }

    #[must_use]
    pub fn with_codex(mut self, codex: Option<&'a CodexControllerHandle>) -> Self {
        self.codex = codex;
        self
    }

    #[must_use]
    pub const fn none() -> Self {
        Self {
            agent_tui: None,
            acp_agent: None,
            codex: None,
        }
    }
}

/// Route a `TaskDropEffect::Started` record takes when the daemon tries to
/// actively wake the worker. Carries borrowed handles so the caller can
/// dispatch the wake without re-doing the lookup.
pub(crate) enum WakeRoute<'a> {
    Tui {
        tui_id: &'a str,
        manager: &'a AgentTuiManagerHandle,
    },
    Acp {
        acp_id: &'a str,
        manager: &'a AcpAgentManagerHandle,
    },
    Codex {
        run_id: &'a str,
        controller: &'a CodexControllerHandle,
    },
    None {
        reason: NoneReason,
    },
}

/// Closed alphabet of reasons the daemon could not actively wake an agent.
///
/// Tracing renders via [`Display`]; tests assert via the enum so a renamed
/// log message does not silently invalidate a test grep.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NoneReason {
    /// Agent id appeared in the task-drop effect but the session has no
    /// matching `AgentRegistration`.
    Unregistered,
    /// Agent registration exists but does not carry a `managed_agent` ref;
    /// the daemon has no transport handle to reach it.
    Unmanaged,
    /// Tui-managed registration is missing the managed-agent identity needed
    /// to target the live TUI.
    MissingTuiIdentity,
    /// Tui-managed agent but the daemon has no `AgentTuiManager` handle in
    /// the current dispatch context.
    NoTuiManager,
    /// Acp-managed agent but the daemon has no `AcpAgentManager` handle in
    /// the current dispatch context.
    NoAcpManager,
    /// Codex-managed agent but the daemon has no `CodexController` handle in
    /// the current dispatch context.
    NoCodexController,
}

impl fmt::Display for NoneReason {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Unregistered => "agent not registered",
            Self::Unmanaged => "agent not daemon-managed",
            Self::MissingTuiIdentity => "tui-managed agent missing managed-agent identity",
            Self::NoTuiManager => "tui-managed agent but no AgentTuiManager available",
            Self::NoAcpManager => "acp-managed agent but no AcpAgentManager available",
            Self::NoCodexController => "codex-managed agent but no CodexController available",
        })
    }
}

/// Pick the correct wake transport for an agent registration.
///
/// `Tui` route requires a TUI-kind `managed_agent` identity and a live
/// `AgentTuiManager`. `Acp` route requires the registration's `managed_agent`
/// to be `Acp`-kind and a live `AcpAgentManager`. Anything else falls through
/// to `None` with a descriptive reason so callers can log why an active wake
/// is impossible (the file-based signal still queues so the agent recovers
/// on its next poll).
pub(crate) fn wake_route_for_registration<'a>(
    registration: Option<&'a AgentRegistration>,
    dispatch: WakeDispatch<'a>,
) -> WakeRoute<'a> {
    let Some(registration) = registration else {
        return WakeRoute::None {
            reason: NoneReason::Unregistered,
        };
    };
    match registration.managed_agent.as_ref() {
        Some(ManagedAgentRef {
            kind: ManagedAgentKind::Tui,
            ..
        }) => tui_route(registration, dispatch.agent_tui),
        Some(ManagedAgentRef {
            kind: ManagedAgentKind::Acp,
            id: acp_id,
        }) => acp_route(acp_id, dispatch.acp_agent),
        Some(ManagedAgentRef {
            kind: ManagedAgentKind::Codex,
            id: run_id,
        }) => codex_route(run_id, dispatch.codex),
        None => WakeRoute::None {
            reason: NoneReason::Unmanaged,
        },
    }
}

fn tui_route<'a>(
    registration: &'a AgentRegistration,
    agent_tui_manager: Option<&'a AgentTuiManagerHandle>,
) -> WakeRoute<'a> {
    match (
        managed_tui_id_for_registration(registration),
        agent_tui_manager,
    ) {
        (Some(tui_id), Some(manager)) => WakeRoute::Tui { tui_id, manager },
        (None, _) => WakeRoute::None {
            reason: NoneReason::MissingTuiIdentity,
        },
        (_, None) => WakeRoute::None {
            reason: NoneReason::NoTuiManager,
        },
    }
}

fn acp_route<'a>(
    acp_id: &'a str,
    acp_agent_manager: Option<&'a AcpAgentManagerHandle>,
) -> WakeRoute<'a> {
    match acp_agent_manager {
        Some(manager) => WakeRoute::Acp { acp_id, manager },
        None => WakeRoute::None {
            reason: NoneReason::NoAcpManager,
        },
    }
}

fn codex_route<'a>(
    run_id: &'a str,
    codex_controller: Option<&'a CodexControllerHandle>,
) -> WakeRoute<'a> {
    match codex_controller {
        Some(controller) => WakeRoute::Codex { run_id, controller },
        None => WakeRoute::None {
            reason: NoneReason::NoCodexController,
        },
    }
}

pub(crate) fn log_wake_attempt(
    session_id: &str,
    record: &session_service::TaskStartSignalRecord,
    route: &WakeRoute<'_>,
) {
    let (managed_kind, route_target): (&str, Cow<'_, str>) = match route {
        WakeRoute::Tui { tui_id, .. } => ("tui", (*tui_id).into()),
        WakeRoute::Acp { acp_id, .. } => ("acp", (*acp_id).into()),
        WakeRoute::Codex { run_id, .. } => ("codex", (*run_id).into()),
        WakeRoute::None { reason } => ("none", reason.to_string().into()),
    };
    record_wake_event(
        WakeEventLevel::Info,
        "attempt",
        &[
            ("managed_kind", &managed_kind),
            ("route_target", &route_target),
            ("session_id", &session_id),
            ("agent_id", &record.agent_id),
            ("runtime", &record.runtime),
            ("signal_id", &record.signal.signal_id),
        ],
    );
}

#[cfg(test)]
mod tests {
    use super::{NoneReason, WakeDispatch, WakeRoute, wake_route_for_registration};
    use crate::agents::kind::{AcpAgentId, RuntimeKind};
    use crate::agents::runtime::RuntimeCapabilities;
    use crate::daemon::service::signals::managed_tui_id_for_registration;
    use crate::session::types::{
        AgentRegistration, AgentStatus, ManagedAgentKind, ManagedAgentRef, SessionRole,
    };
    use std::sync::{Arc, OnceLock};
    use tokio::sync::broadcast;

    fn registration(
        capabilities: Vec<String>,
        managed_agent: Option<ManagedAgentRef>,
    ) -> AgentRegistration {
        AgentRegistration {
            agent_id: "agent-1".into(),
            name: "Agent".into(),
            runtime: RuntimeKind::Acp(AcpAgentId::new("test")),
            role: SessionRole::Worker,
            capabilities,
            joined_at: "0".into(),
            updated_at: "0".into(),
            status: AgentStatus::Active,
            agent_session_id: None,
            managed_agent,
            last_activity_at: None,
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        }
    }

    fn tui_handle() -> crate::daemon::agent_tui::AgentTuiManagerHandle {
        let (sender, _receiver) = broadcast::channel(1);
        crate::daemon::agent_tui::AgentTuiManagerHandle::new(
            sender,
            Arc::new(OnceLock::new()),
            false,
        )
    }

    fn acp_handle() -> crate::daemon::agent_acp::AcpAgentManagerHandle {
        let (sender, _receiver) = broadcast::channel(1);
        crate::daemon::agent_acp::AcpAgentManagerHandle::new(sender, Arc::new(OnceLock::new()))
    }

    fn codex_handle() -> crate::daemon::codex_controller::CodexControllerHandle {
        let (sender, _receiver) = broadcast::channel(1);
        crate::daemon::codex_controller::CodexControllerHandle::new(
            sender,
            Arc::new(OnceLock::new()),
            false,
        )
    }

    fn assert_none_reason(route: &WakeRoute<'_>, expected: NoneReason) {
        match route {
            WakeRoute::None { reason } => assert_eq!(*reason, expected),
            other => panic!("expected None route, got {:?}", managed_kind_label(other)),
        }
    }

    #[test]
    fn returns_none_for_missing_registration() {
        let route = wake_route_for_registration(None, WakeDispatch::none());
        assert_none_reason(&route, NoneReason::Unregistered);
    }

    #[test]
    fn returns_none_for_unmanaged_agent() {
        let reg = registration(vec![], None);
        let route = wake_route_for_registration(Some(&reg), WakeDispatch::none());
        assert_none_reason(&route, NoneReason::Unmanaged);
    }

    #[test]
    fn wake_route_ignores_legacy_tui_capability_without_managed_ref() {
        let reg = registration(vec!["agent-tui:legacy-tui".into()], None);

        assert_eq!(managed_tui_id_for_registration(&reg), None);

        let route = wake_route_for_registration(Some(&reg), WakeDispatch::none());
        assert_none_reason(&route, NoneReason::Unmanaged);
    }

    #[test]
    fn returns_tui_for_tui_managed_with_handle() {
        let reg = registration(vec![], Some(ManagedAgentRef::tui("managed-tui-id")));
        let tui = tui_handle();
        let route = wake_route_for_registration(Some(&reg), WakeDispatch::new(Some(&tui), None));
        match route {
            WakeRoute::Tui { tui_id, .. } => assert_eq!(tui_id, "managed-tui-id"),
            other => panic!("expected Tui route, got {:?}", managed_kind_label(&other)),
        }
    }

    #[test]
    fn signal_delivery_prefers_managed_tui_identity_over_legacy_capability_tag() {
        let reg = registration(
            vec!["agent-tui:legacy-tui".into()],
            Some(ManagedAgentRef::tui("managed-tui-id")),
        );

        assert_eq!(
            managed_tui_id_for_registration(&reg),
            Some("managed-tui-id")
        );
    }

    #[test]
    fn returns_none_when_tui_managed_identity_is_empty() {
        let reg = registration(vec![], Some(ManagedAgentRef::tui("")));
        let tui = tui_handle();
        let route = wake_route_for_registration(Some(&reg), WakeDispatch::new(Some(&tui), None));
        assert_none_reason(&route, NoneReason::MissingTuiIdentity);
    }

    #[test]
    fn returns_none_when_tui_managed_without_handle() {
        let reg = registration(vec![], Some(ManagedAgentRef::tui("managed-tui-id")));
        let route = wake_route_for_registration(Some(&reg), WakeDispatch::none());
        assert_none_reason(&route, NoneReason::NoTuiManager);
    }

    #[test]
    fn returns_acp_for_acp_managed_with_handle() {
        let reg = registration(vec![], Some(ManagedAgentRef::acp("acp-7")));
        let acp = acp_handle();
        let route = wake_route_for_registration(Some(&reg), WakeDispatch::new(None, Some(&acp)));
        match route {
            WakeRoute::Acp { acp_id, .. } => assert_eq!(acp_id, "acp-7"),
            other => panic!("expected Acp route, got {:?}", managed_kind_label(&other)),
        }
    }

    #[test]
    fn returns_none_when_acp_managed_without_handle() {
        let reg = registration(vec![], Some(ManagedAgentRef::acp("acp-7")));
        let route = wake_route_for_registration(Some(&reg), WakeDispatch::none());
        assert_none_reason(&route, NoneReason::NoAcpManager);
    }

    #[test]
    fn returns_codex_for_codex_managed_with_handle() {
        let reg = registration(vec![], Some(ManagedAgentRef::codex("codex-7")));
        let codex = codex_handle();
        let route = wake_route_for_registration(
            Some(&reg),
            WakeDispatch::new(None, None).with_codex(Some(&codex)),
        );
        match route {
            WakeRoute::Codex { run_id, .. } => assert_eq!(run_id, "codex-7"),
            other => panic!("expected Codex route, got {:?}", managed_kind_label(&other)),
        }
    }

    #[test]
    fn returns_none_when_codex_managed_without_handle() {
        let reg = registration(vec![], Some(ManagedAgentRef::codex("codex-7")));
        let route = wake_route_for_registration(Some(&reg), WakeDispatch::none());
        assert_none_reason(&route, NoneReason::NoCodexController);
    }

    #[test]
    fn none_reason_display_is_stable() {
        assert_eq!(
            format!("{}", NoneReason::Unregistered),
            "agent not registered"
        );
        assert_eq!(
            format!("{}", NoneReason::Unmanaged),
            "agent not daemon-managed"
        );
        assert_eq!(
            format!("{}", NoneReason::MissingTuiIdentity),
            "tui-managed agent missing managed-agent identity"
        );
        assert_eq!(
            format!("{}", NoneReason::NoTuiManager),
            "tui-managed agent but no AgentTuiManager available"
        );
        assert_eq!(
            format!("{}", NoneReason::NoAcpManager),
            "acp-managed agent but no AcpAgentManager available"
        );
        assert_eq!(
            format!("{}", NoneReason::NoCodexController),
            "codex-managed agent but no CodexController available"
        );
    }

    #[test]
    fn acp_route_chosen_even_when_tui_handle_present() {
        let reg = registration(vec![], Some(ManagedAgentRef::acp("acp-7")));
        let tui = tui_handle();
        let acp = acp_handle();
        let route =
            wake_route_for_registration(Some(&reg), WakeDispatch::new(Some(&tui), Some(&acp)));
        assert!(matches!(route, WakeRoute::Acp { .. }));
        let _ = ManagedAgentKind::Tui;
    }

    fn managed_kind_label(route: &WakeRoute<'_>) -> &'static str {
        match route {
            WakeRoute::Tui { .. } => "tui",
            WakeRoute::Acp { .. } => "acp",
            WakeRoute::Codex { .. } => "codex",
            WakeRoute::None { .. } => "none",
        }
    }
}
