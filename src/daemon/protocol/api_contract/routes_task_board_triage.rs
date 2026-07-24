use super::{
    HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, WsExemptionKind, http_paths, ws_methods,
};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ITEM_TRIAGE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_TRIAGE_GET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ITEM_TRIAGE_HISTORY,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_TRIAGE_HISTORY,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_ITEM_TRIAGE_OVERRIDE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_SET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_ITEM_TRIAGE_OVERRIDE_CLEAR,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_CLEAR,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_TRIAGE_RULES_DRAFT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_TRIAGE_RULES_DRAFT_GET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_TRIAGE_RULES_DRAFT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_TRIAGE_RULES_DRAFT_SAVE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_TRIAGE_RULES_PREVIEW,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_TRIAGE_RULES_PREVIEW,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_TRIAGE_RULES_ACTIVATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_TRIAGE_RULES_ACTIVATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_TRIAGE_RULES_REVISIONS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_TRIAGE_RULES_REVISIONS,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_TRIAGE_RULES_AUDIT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_TRIAGE_RULES_AUDIT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_TRIAGE_ESCALATION_VERDICT,
        parity: HttpRouteParity::Exempt {
            kind: WsExemptionKind::StandingDecision,
            reason: "HTTP-only local report from the daemon's own spawned escalation worker, \
                     authenticated by a single-use per-escalation token minted at claim time, \
                     not the control-plane session -- never exposed to remote or Swift clients",
        },
        swift_client_exposed: false,
    },
];
