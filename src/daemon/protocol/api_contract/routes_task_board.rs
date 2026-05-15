use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_ITEMS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_CREATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ITEMS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_LIST,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ITEM,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_GET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_ITEM,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_UPDATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Delete,
        path: http_paths::TASK_BOARD_ITEM,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_DELETE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_PLAN_BEGIN,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_PLAN_BEGIN,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_PLAN_SUBMIT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_PLAN_SUBMIT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_PLAN_APPROVE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_PLAN_APPROVE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_SYNC,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_SYNC,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_DISPATCH,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_DISPATCH,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_EVALUATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_EVALUATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_AUDIT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_AUDIT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_PROJECTS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_PROJECTS,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_MACHINES,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_MACHINES,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_HOST_LOCAL,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_HOST_LOCAL,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_HOST_LIST,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_HOST_LIST,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_HOST_SET_PROJECT_TYPES,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_HOST_SET_PROJECT_TYPES,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_STATUS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_START,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_START,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_STOP,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_STOP,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_GET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_POLICY_PIPELINE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_POLICY_PIPELINE_GET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_POLICY_PIPELINE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_POLICY_SIMULATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_POLICY_PIPELINE_SIMULATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_POLICY_PROMOTE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_POLICY_PIPELINE_PROMOTE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_POLICY_AUDIT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT,
        },
        swift_client_exposed: true,
    },
];
