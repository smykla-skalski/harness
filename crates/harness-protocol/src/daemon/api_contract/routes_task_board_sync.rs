use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

pub(super) const SYNC: HttpApiRouteContract = HttpApiRouteContract {
    method: HttpRouteMethod::Post,
    path: http_paths::TASK_BOARD_SYNC,
    parity: HttpRouteParity::Rpc {
        ws_method: ws_methods::TASK_BOARD_SYNC,
    },
    swift_client_exposed: true,
};

pub(super) const SYNC_CANCEL: HttpApiRouteContract = HttpApiRouteContract {
    method: HttpRouteMethod::Post,
    path: http_paths::TASK_BOARD_SYNC_CANCEL,
    parity: HttpRouteParity::Rpc {
        ws_method: ws_methods::TASK_BOARD_SYNC_CANCEL,
    },
    swift_client_exposed: true,
};

pub(super) const SYNC_STATUS: HttpApiRouteContract = HttpApiRouteContract {
    method: HttpRouteMethod::Get,
    path: http_paths::TASK_BOARD_SYNC_STATUS,
    parity: HttpRouteParity::Rpc {
        ws_method: ws_methods::TASK_BOARD_SYNC_STATUS,
    },
    swift_client_exposed: true,
};
