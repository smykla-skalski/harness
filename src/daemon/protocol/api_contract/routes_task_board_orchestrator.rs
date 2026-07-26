use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

// Spelled out rather than built by a helper: the Swift parity test reads these
// tables as text, and a constructor hides both the path and the exposure flag
// from it. A route it cannot see is a route whose drift it cannot report.
pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_RUNS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_RUNS,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_METRICS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_METRICS,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_FORCE_CANCEL,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_FORCE_CANCEL,
        },
        swift_client_exposed: true,
    },
];
