//! Initial configuration push frame sent on every WebSocket connection.
//!
//! The frame ships personas and per-runtime model catalogs. It is the first
//! frame written to a client after upgrade so the UI has the data it needs to
//! render the agent startup pickers before the user can interact.

use axum::extract::ws::Message;
use serde_json::Value;

use crate::agents::acp::{catalog, probe};
use crate::agents::runtime::models;
use crate::daemon::protocol::{WS_CONFIG_EVENT, WsConfigPayload, WsPushEvent};
use crate::session::persona;
use crate::workspace::utc_now;

use super::frames::serialize_push_frames;

/// Build the configuration payload from the current persona and model
/// registries.
#[must_use]
pub fn build_config_payload() -> WsConfigPayload {
    WsConfigPayload {
        personas: persona::all(),
        runtime_models: models::all_catalogs(),
        acp_agents: catalog::acp_agents().into_iter().cloned().collect(),
        runtime_probe: probe::cached_probe_snapshot(),
    }
}

/// Build the configuration push frame ready to send through the priority
/// channel. Returns `None` only if serialization fails - which is unreachable
/// in practice but treated defensively so the connection can still proceed.
#[must_use]
pub fn build_config_push_frame() -> Option<Message> {
    let payload = serde_json::to_value(build_config_payload()).ok()?;
    let push = config_push_event(payload);
    let mut frames = serialize_push_frames(&push).ok()?;
    if frames.is_empty() {
        return None;
    }
    Some(frames.remove(0))
}

fn config_push_event(payload: Value) -> WsPushEvent {
    WsPushEvent {
        event: WS_CONFIG_EVENT.to_string(),
        recorded_at: utc_now(),
        session_id: None,
        payload,
        seq: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::acp::probe::{
        AcpAuthState, AcpRuntimeProbe, AcpRuntimeProbeResponse, lock_probe_cache_for_tests,
        replace_probe_cache_for_tests,
    };
    use axum::extract::ws::Message;
    use std::time::Duration;

    #[test]
    fn build_config_payload_includes_known_personas() {
        let payload = build_config_payload();
        let identifiers: Vec<&str> = payload
            .personas
            .iter()
            .map(|persona| persona.identifier.as_str())
            .collect();
        assert!(identifiers.contains(&"code-reviewer"));
        assert!(identifiers.contains(&"debugger"));
    }

    #[test]
    fn build_config_payload_includes_every_runtime_catalog() {
        let payload = build_config_payload();
        let names: Vec<&str> = payload
            .runtime_models
            .iter()
            .map(|catalog| catalog.runtime.as_str())
            .collect();
        for runtime in ["claude", "codex", "gemini", "copilot", "vibe", "opencode"] {
            assert!(
                names.contains(&runtime),
                "missing runtime '{runtime}' in config payload"
            );
        }
    }

    #[test]
    fn build_config_push_frame_serializes_with_config_event_and_seq_zero() {
        let _guard = lock_probe_cache_for_tests();
        replace_probe_cache_for_tests(
            Some(AcpRuntimeProbeResponse {
                probes: vec![AcpRuntimeProbe {
                    agent_id: "copilot".to_string(),
                    display_name: "GitHub Copilot".to_string(),
                    binary_present: true,
                    auth_state: AcpAuthState::Ready,
                    version: Some("1.0.0".to_string()),
                    install_hint: None,
                }],
                checked_at: "2026-05-03T20:00:00Z".to_string(),
            }),
            Duration::ZERO,
            false,
        );
        let frame = build_config_push_frame().expect("config frame");
        let Message::Text(text) = frame else {
            panic!("config frame should be a text message");
        };
        let push: WsPushEvent = serde_json::from_str(&text).expect("deserialize config push event");
        assert_eq!(push.event, WS_CONFIG_EVENT);
        assert_eq!(push.seq, 0);
        assert!(push.session_id.is_none());

        let payload: WsConfigPayload =
            serde_json::from_value(push.payload).expect("deserialize config payload");
        assert!(!payload.personas.is_empty());
        assert!(!payload.runtime_models.is_empty());
        assert!(!payload.acp_agents.is_empty());
        assert!(payload.runtime_probe.is_some());
        replace_probe_cache_for_tests(None, Duration::ZERO, false);
    }

    #[test]
    fn build_config_payload_omits_runtime_probe_until_cache_is_ready() {
        let _guard = lock_probe_cache_for_tests();
        replace_probe_cache_for_tests(None, Duration::ZERO, true);

        let payload = build_config_payload();

        assert!(payload.runtime_probe.is_none());
        replace_probe_cache_for_tests(None, Duration::ZERO, false);
    }
}
