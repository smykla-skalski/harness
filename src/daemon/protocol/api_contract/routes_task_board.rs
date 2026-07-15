use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_CAPABILITIES,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_CAPABILITIES,
        },
        swift_client_exposed: true,
    },
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
        path: http_paths::TASK_BOARD_PLAN_REVOKE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_PLAN_REVOKE,
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
        path: http_paths::TASK_BOARD_DISPATCH_DELIVER,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_DISPATCH_DELIVER,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_DISPATCH_PICK,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_DISPATCH_PICK,
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
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_ORCHESTRATOR_OPENROUTER_TOKEN,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_ORCHESTRATOR_OPENROUTER_TOKEN_SYNC,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_GIT_SIGNING_VERIFY,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_GIT_SIGNING_VERIFY,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_GIT_RUNTIME_KEY_MATERIAL,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_GIT_RUNTIME_KEY_MATERIAL_SYNC,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_ACK,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_ACK,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::POLICY_CANVASES,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_CANVAS_WORKSPACE_GET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_CANVASES_CREATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_CANVAS_CREATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_CANVASES_DUPLICATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_CANVAS_DUPLICATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_CANVASES_RENAME,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_CANVAS_RENAME,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_CANVASES_ACTIVE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_CANVAS_SET_ACTIVE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_CANVASES_DELETE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_CANVAS_DELETE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_CANVASES_GLOBAL_ENFORCEMENT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_CANVAS_SET_GLOBAL_ENFORCEMENT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_CANVASES_SPAWN_REQUIRES_LIVE_POLICY,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_CANVAS_SET_SPAWN_REQUIRES_LIVE_POLICY,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_CANVASES_SPAWN_KILL_SWITCH,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_CANVAS_SET_SPAWN_KILL_SWITCH,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::POLICY_APPROVAL_GRANTS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_APPROVAL_GRANTS_LIST,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_APPROVAL_GRANT_RESOLVE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_APPROVAL_GRANT_RESOLVE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_APPROVAL_GRANT_REVOKE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_APPROVAL_GRANT_REVOKE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::POLICY_PIPELINE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_PIPELINE_GET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::POLICY_PIPELINE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_PIPELINE_SAVE_DRAFT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_SIMULATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_PIPELINE_SIMULATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_PROMOTE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_PIPELINE_PROMOTE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::POLICY_AUDIT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_PIPELINE_AUDIT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_CANVAS_EXPORT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_CANVAS_EXPORT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_CANVAS_IMPORT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_CANVAS_IMPORT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_SCENARIOS_CREATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_SCENARIO_CREATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_SCENARIOS_UPDATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_SCENARIO_UPDATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_SCENARIOS_DELETE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_SCENARIO_DELETE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_SCENARIOS_RESET,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_SCENARIO_RESET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_MAKE_LIVE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_PIPELINE_MAKE_LIVE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_GO_LIVE_DIFF,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_PIPELINE_GO_LIVE_DIFF,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICY_REPLAY,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::POLICY_PIPELINE_REPLAY,
        },
        swift_client_exposed: true,
    },
];
