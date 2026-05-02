use super::{HttpApiRouteContract, HttpRouteParity, HttpRouteMethod, http_paths, ws_methods};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
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
        method: HttpRouteMethod::Get,
        path: http_paths::CONFIG,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::CONFIG,
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
        path: http_paths::RUNTIMES_PROBE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::RUNTIMES_PROBE,
        },
        swift_client_exposed: true,
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
        path: http_paths::SESSION_ARCHIVE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::SESSION_ARCHIVE,
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
];
