#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpRouteMethod {
    Get,
    Post,
    Put,
    Delete,
}

impl HttpRouteMethod {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Get => "GET",
            Self::Post => "POST",
            Self::Put => "PUT",
            Self::Delete => "DELETE",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpRouteParity {
    Rpc { ws_method: &'static str },
    Exempt { reason: &'static str },
}

impl HttpRouteParity {
    #[must_use]
    pub const fn ws_method(self) -> Option<&'static str> {
        match self {
            Self::Rpc { ws_method } => Some(ws_method),
            Self::Exempt { .. } => None,
        }
    }

    #[must_use]
    pub const fn exemption_reason(self) -> Option<&'static str> {
        match self {
            Self::Rpc { .. } => None,
            Self::Exempt { reason } => Some(reason),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HttpApiRouteContract {
    pub method: HttpRouteMethod,
    pub path: &'static str,
    pub parity: HttpRouteParity,
    pub swift_client_exposed: bool,
}

pub mod http_paths {
    pub const HEALTH: &str = "/v1/health";
    pub const READY: &str = "/v1/ready";
    pub const DIAGNOSTICS: &str = "/v1/diagnostics";
    pub const DAEMON_STOP: &str = "/v1/daemon/stop";
    pub const BRIDGE_RECONFIGURE: &str = "/v1/bridge/reconfigure";
    pub const DAEMON_LOG_LEVEL: &str = "/v1/daemon/log-level";
    pub const PROJECTS: &str = "/v1/projects";
    pub const RUNTIME_SESSION_RESOLVE: &str = "/v1/runtime-sessions/resolve";
    pub const WS: &str = "/v1/ws";
    pub const STREAM: &str = "/v1/stream";
    pub const SESSIONS: &str = "/v1/sessions";
    pub const SESSIONS_ADOPT: &str = "/v1/sessions/adopt";
    pub const SESSION_DETAIL: &str = "/v1/sessions/{session_id}";
    pub const SESSION_TIMELINE: &str = "/v1/sessions/{session_id}/timeline";
    pub const SESSION_STREAM: &str = "/v1/sessions/{session_id}/stream";
    pub const SESSION_JOIN: &str = "/v1/sessions/{session_id}/join";
    pub const SESSION_RUNTIME_SESSION: &str = "/v1/sessions/{session_id}/runtime-session";
    pub const SESSION_TITLE: &str = "/v1/sessions/{session_id}/title";
    pub const SESSION_END: &str = "/v1/sessions/{session_id}/end";
    pub const SESSION_LEAVE: &str = "/v1/sessions/{session_id}/leave";
    pub const SESSION_OBSERVE: &str = "/v1/sessions/{session_id}/observe";
    pub const SESSION_TASK_CREATE: &str = "/v1/sessions/{session_id}/task";
    pub const SESSION_TASK_ASSIGN: &str = "/v1/sessions/{session_id}/tasks/{task_id}/assign";
    pub const SESSION_TASK_DROP: &str = "/v1/sessions/{session_id}/tasks/{task_id}/drop";
    pub const SESSION_TASK_QUEUE_POLICY: &str =
        "/v1/sessions/{session_id}/tasks/{task_id}/queue-policy";
    pub const SESSION_TASK_UPDATE: &str = "/v1/sessions/{session_id}/tasks/{task_id}/status";
    pub const SESSION_TASK_CHECKPOINT: &str =
        "/v1/sessions/{session_id}/tasks/{task_id}/checkpoint";
    pub const SESSION_AGENT_ROLE: &str = "/v1/sessions/{session_id}/agents/{agent_id}/role";
    pub const SESSION_AGENT_REMOVE: &str = "/v1/sessions/{session_id}/agents/{agent_id}/remove";
    pub const SESSION_LEADER_TRANSFER: &str = "/v1/sessions/{session_id}/leader";
    pub const SESSION_MANAGED_AGENTS: &str = "/v1/sessions/{session_id}/managed-agents";
    pub const SESSION_MANAGED_AGENTS_TERMINAL: &str =
        "/v1/sessions/{session_id}/managed-agents/terminal";
    pub const SESSION_MANAGED_AGENTS_CODEX: &str = "/v1/sessions/{session_id}/managed-agents/codex";
    pub const MANAGED_AGENT_DETAIL: &str = "/v1/managed-agents/{agent_id}";
    pub const MANAGED_AGENT_INPUT: &str = "/v1/managed-agents/{agent_id}/input";
    pub const MANAGED_AGENT_RESIZE: &str = "/v1/managed-agents/{agent_id}/resize";
    pub const MANAGED_AGENT_STOP: &str = "/v1/managed-agents/{agent_id}/stop";
    pub const MANAGED_AGENT_READY: &str = "/v1/managed-agents/{agent_id}/ready";
    pub const MANAGED_AGENT_ATTACH: &str = "/v1/managed-agents/{agent_id}/attach";
    pub const MANAGED_AGENT_STEER: &str = "/v1/managed-agents/{agent_id}/steer";
    pub const MANAGED_AGENT_INTERRUPT: &str = "/v1/managed-agents/{agent_id}/interrupt";
    pub const MANAGED_AGENT_APPROVAL: &str =
        "/v1/managed-agents/{agent_id}/approvals/{approval_id}";
    pub const SESSION_SIGNAL_SEND: &str = "/v1/sessions/{session_id}/signal";
    pub const SESSION_SIGNAL_CANCEL: &str = "/v1/sessions/{session_id}/signal-cancel";
    pub const SESSION_SIGNAL_ACK: &str = "/v1/sessions/{session_id}/signal-ack";
    pub const SESSION_VOICE_START: &str = "/v1/sessions/{session_id}/voice-sessions";
    pub const VOICE_AUDIO_APPEND: &str = "/v1/voice-sessions/{voice_session_id}/audio";
    pub const VOICE_TRANSCRIPT_APPEND: &str = "/v1/voice-sessions/{voice_session_id}/transcript";
    pub const VOICE_FINISH: &str = "/v1/voice-sessions/{voice_session_id}/finish";
}

pub mod ws_methods {
    pub const PING: &str = "ping";
    pub const HEALTH: &str = "health";
    pub const DIAGNOSTICS: &str = "diagnostics";
    pub const DAEMON_STOP: &str = "daemon.stop";
    pub const BRIDGE_RECONFIGURE: &str = "bridge.reconfigure";
    pub const DAEMON_LOG_LEVEL: &str = "daemon.log_level";
    pub const DAEMON_SET_LOG_LEVEL: &str = "daemon.set_log_level";
    pub const PROJECTS: &str = "projects";
    pub const SESSIONS: &str = "sessions";
    pub const RUNTIME_SESSION_RESOLVE: &str = "runtime_session.resolve";
    pub const STREAM_SUBSCRIBE: &str = "stream.subscribe";
    pub const STREAM_UNSUBSCRIBE: &str = "stream.unsubscribe";
    pub const SESSION_DETAIL: &str = "session.detail";
    pub const SESSION_TIMELINE: &str = "session.timeline";
    pub const SESSION_SUBSCRIBE: &str = "session.subscribe";
    pub const SESSION_UNSUBSCRIBE: &str = "session.unsubscribe";
    pub const SESSION_START: &str = "session.start";
    pub const SESSION_ADOPT: &str = "session.adopt";
    pub const SESSION_DELETE: &str = "session.delete";
    pub const SESSION_JOIN: &str = "session.join";
    pub const SESSION_RUNTIME_SESSION: &str = "session.runtime_session";
    pub const SESSION_TITLE: &str = "session.title";
    pub const SESSION_END: &str = "session.end";
    pub const SESSION_LEAVE: &str = "session.leave";
    pub const SESSION_OBSERVE: &str = "session.observe";
    pub const TASK_CREATE: &str = "task.create";
    pub const TASK_ASSIGN: &str = "task.assign";
    pub const TASK_DROP: &str = "task.drop";
    pub const TASK_QUEUE_POLICY: &str = "task.queue_policy";
    pub const TASK_UPDATE: &str = "task.update";
    pub const TASK_CHECKPOINT: &str = "task.checkpoint";
    pub const AGENT_CHANGE_ROLE: &str = "agent.change_role";
    pub const AGENT_REMOVE: &str = "agent.remove";
    pub const LEADER_TRANSFER: &str = "leader.transfer";
    pub const SESSION_MANAGED_AGENTS: &str = "session.managed_agents";
    pub const MANAGED_AGENT_START_TERMINAL: &str = "managed_agent.start_terminal";
    pub const MANAGED_AGENT_START_CODEX: &str = "managed_agent.start_codex";
    pub const MANAGED_AGENT_DETAIL: &str = "managed_agent.detail";
    pub const MANAGED_AGENT_INPUT: &str = "managed_agent.input";
    pub const MANAGED_AGENT_RESIZE: &str = "managed_agent.resize";
    pub const MANAGED_AGENT_STOP: &str = "managed_agent.stop";
    pub const MANAGED_AGENT_READY: &str = "managed_agent.ready";
    pub const MANAGED_AGENT_STEER_CODEX: &str = "managed_agent.steer_codex";
    pub const MANAGED_AGENT_INTERRUPT_CODEX: &str = "managed_agent.interrupt_codex";
    pub const MANAGED_AGENT_RESOLVE_CODEX_APPROVAL: &str = "managed_agent.resolve_codex_approval";
    pub const SIGNAL_SEND: &str = "signal.send";
    pub const SIGNAL_CANCEL: &str = "signal.cancel";
    pub const SIGNAL_ACK: &str = "signal.ack";
    pub const VOICE_START_SESSION: &str = "voice.start_session";
    pub const VOICE_APPEND_AUDIO: &str = "voice.append_audio";
    pub const VOICE_APPEND_TRANSCRIPT: &str = "voice.append_transcript";
    pub const VOICE_FINISH_SESSION: &str = "voice.finish_session";
}

pub const HTTP_API_CONTRACT: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::HEALTH,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::HEALTH,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::READY,
        parity: HttpRouteParity::Exempt {
            reason: "daemon readiness probe remains plain HTTP",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::DIAGNOSTICS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DIAGNOSTICS,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DAEMON_STOP,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DAEMON_STOP,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::BRIDGE_RECONFIGURE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::BRIDGE_RECONFIGURE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::DAEMON_LOG_LEVEL,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DAEMON_LOG_LEVEL,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::DAEMON_LOG_LEVEL,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DAEMON_SET_LOG_LEVEL,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::PROJECTS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::PROJECTS,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::RUNTIME_SESSION_RESOLVE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::RUNTIME_SESSION_RESOLVE,
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::WS,
        parity: HttpRouteParity::Exempt {
            reason: "websocket upgrade transport is not an RPC endpoint",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::STREAM,
        parity: HttpRouteParity::Exempt {
            reason: "server-sent global stream remains a transport endpoint",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::SESSIONS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSIONS,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSIONS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_START,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSIONS_ADOPT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_ADOPT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::SESSION_DETAIL,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_DETAIL,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Delete,
        path: http_paths::SESSION_DETAIL,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_DELETE,
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::SESSION_TIMELINE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_TIMELINE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::SESSION_STREAM,
        parity: HttpRouteParity::Exempt {
            reason: "server-sent session stream remains a transport endpoint",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_JOIN,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_JOIN,
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_RUNTIME_SESSION,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_RUNTIME_SESSION,
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_TITLE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_TITLE,
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_END,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_END,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_LEAVE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_LEAVE,
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_OBSERVE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_OBSERVE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_TASK_CREATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_CREATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_TASK_ASSIGN,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_ASSIGN,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_TASK_DROP,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_DROP,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_TASK_QUEUE_POLICY,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_QUEUE_POLICY,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_TASK_UPDATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_UPDATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_TASK_CHECKPOINT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_CHECKPOINT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_AGENT_ROLE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::AGENT_CHANGE_ROLE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_AGENT_REMOVE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::AGENT_REMOVE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_LEADER_TRANSFER,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::LEADER_TRANSFER,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::SESSION_MANAGED_AGENTS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_MANAGED_AGENTS,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_MANAGED_AGENTS_TERMINAL,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_START_TERMINAL,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_MANAGED_AGENTS_CODEX,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_START_CODEX,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::MANAGED_AGENT_DETAIL,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_DETAIL,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::MANAGED_AGENT_INPUT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_INPUT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::MANAGED_AGENT_RESIZE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_RESIZE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::MANAGED_AGENT_STOP,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_STOP,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::MANAGED_AGENT_READY,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_READY,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::MANAGED_AGENT_ATTACH,
        parity: HttpRouteParity::Exempt {
            reason: "managed agent attach upgrades into a raw terminal stream",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::MANAGED_AGENT_STEER,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_STEER_CODEX,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::MANAGED_AGENT_INTERRUPT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_INTERRUPT_CODEX,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::MANAGED_AGENT_APPROVAL,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_RESOLVE_CODEX_APPROVAL,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_SIGNAL_SEND,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SIGNAL_SEND,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_SIGNAL_CANCEL,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SIGNAL_CANCEL,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_SIGNAL_ACK,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SIGNAL_ACK,
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_VOICE_START,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::VOICE_START_SESSION,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::VOICE_AUDIO_APPEND,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::VOICE_APPEND_AUDIO,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::VOICE_TRANSCRIPT_APPEND,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::VOICE_APPEND_TRANSCRIPT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::VOICE_FINISH,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::VOICE_FINISH_SESSION,
        },
        swift_client_exposed: true,
    },
];

#[must_use]
pub fn mapped_ws_methods() -> Vec<&'static str> {
    HTTP_API_CONTRACT
        .iter()
        .filter_map(|route| route.parity.ws_method())
        .collect()
}

#[must_use]
pub fn explicit_exemptions() -> Vec<&'static HttpApiRouteContract> {
    HTTP_API_CONTRACT
        .iter()
        .filter(|route| matches!(route.parity, HttpRouteParity::Exempt { .. }))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn every_non_exempt_http_route_has_a_ws_mapping() {
        for route in HTTP_API_CONTRACT {
            if matches!(route.parity, HttpRouteParity::Exempt { .. }) {
                continue;
            }
            assert!(
                route.parity.ws_method().is_some(),
                "{} {} should map to websocket",
                route.method.as_str(),
                route.path
            );
        }
    }

    #[test]
    fn explicit_non_rpc_exemptions_are_documented_and_stable() {
        let exemptions = explicit_exemptions();
        assert_eq!(exemptions.len(), 5, "unexpected exemption count");
        let exempt_paths: BTreeSet<_> = exemptions.iter().map(|route| route.path).collect();
        assert_eq!(
            exempt_paths,
            BTreeSet::from([
                http_paths::WS,
                http_paths::STREAM,
                http_paths::SESSION_STREAM,
                http_paths::READY,
                http_paths::MANAGED_AGENT_ATTACH,
            ])
        );
        assert!(exemptions.iter().all(|route| {
            route
                .parity
                .exemption_reason()
                .is_some_and(|reason| !reason.is_empty())
        }));
    }

    #[test]
    fn mapped_ws_methods_are_unique() {
        let methods = mapped_ws_methods();
        let unique: BTreeSet<_> = methods.iter().copied().collect();
        assert_eq!(
            methods.len(),
            unique.len(),
            "duplicate websocket method mapping"
        );
    }
}
