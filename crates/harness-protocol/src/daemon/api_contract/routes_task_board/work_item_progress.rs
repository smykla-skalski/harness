use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

pub(super) const READ_ROUTE: HttpApiRouteContract = HttpApiRouteContract {
    method: HttpRouteMethod::Get,
    path: http_paths::TASK_BOARD_ITEM_PROGRESS,
    parity: HttpRouteParity::Rpc {
        ws_method: ws_methods::TASK_BOARD_PROGRESS_GET,
    },
    swift_client_exposed: true,
};

pub(super) const REPORT_ROUTE: HttpApiRouteContract = HttpApiRouteContract {
    method: HttpRouteMethod::Post,
    path: http_paths::TASK_BOARD_ITEM_PROGRESS_REPORT,
    parity: HttpRouteParity::Rpc {
        ws_method: ws_methods::TASK_BOARD_PROGRESS_REPORT,
    },
    swift_client_exposed: true,
};
