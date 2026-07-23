use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

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
];
