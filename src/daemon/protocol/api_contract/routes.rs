use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

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
        path: http_paths::SESSION_TASK_SUBMIT_FOR_REVIEW,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_SUBMIT_FOR_REVIEW,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_TASK_CLAIM_REVIEW,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_CLAIM_REVIEW,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_TASK_SUBMIT_REVIEW,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_SUBMIT_REVIEW,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_TASK_RESPOND_REVIEW,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_RESPOND_REVIEW,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_TASK_ARBITRATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_ARBITRATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_IMPROVER_APPLY,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::IMPROVER_APPLY,
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
        method: HttpRouteMethod::Post,
        path: http_paths::SESSION_MANAGED_AGENTS_ACP,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_START_ACP,
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
        path: http_paths::MANAGED_AGENT_ACP_PERMISSION,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_RESOLVE_ACP_PERMISSION,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Delete,
        path: http_paths::MANAGED_AGENT_DELETE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::MANAGED_AGENT_STOP_ACP,
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
