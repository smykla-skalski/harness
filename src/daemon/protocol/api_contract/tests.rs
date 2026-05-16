use super::*;
use std::collections::BTreeSet;

#[test]
fn every_non_exempt_http_route_has_a_ws_mapping() {
    for route in HTTP_API_CONTRACT.iter() {
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
    assert_eq!(exemptions.len(), 6, "unexpected exemption count");
    let exempt_paths: BTreeSet<_> = exemptions.iter().map(|route| route.path).collect();
    assert_eq!(
        exempt_paths,
        BTreeSet::from([
            http_paths::DAEMON_TELEMETRY,
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
fn config_route_is_swift_exposed_rpc() {
    let route = HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == http_paths::CONFIG)
        .expect("config route should be registered");
    assert_eq!(route.method, HttpRouteMethod::Get);
    assert!(route.swift_client_exposed);
    match route.parity {
        HttpRouteParity::Rpc { ws_method } => assert_eq!(ws_method, ws_methods::CONFIG),
        HttpRouteParity::Exempt { .. } => panic!("config route must use websocket parity"),
    }
}

#[test]
fn task_board_routes_have_complete_ws_parity() {
    let task_board_routes = super::routes_task_board::ROUTES;
    let actual: Vec<_> = task_board_routes
        .iter()
        .map(|route| {
            let ws_method = route
                .parity
                .ws_method()
                .expect("task-board route should map to websocket");
            (
                route.method,
                route.path,
                ws_method,
                route.swift_client_exposed,
            )
        })
        .collect();
    assert_eq!(
        actual,
        vec![
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_ITEMS,
                ws_methods::TASK_BOARD_CREATE,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_ITEMS,
                ws_methods::TASK_BOARD_LIST,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_ITEM,
                ws_methods::TASK_BOARD_GET,
                true,
            ),
            (
                HttpRouteMethod::Put,
                http_paths::TASK_BOARD_ITEM,
                ws_methods::TASK_BOARD_UPDATE,
                true,
            ),
            (
                HttpRouteMethod::Delete,
                http_paths::TASK_BOARD_ITEM,
                ws_methods::TASK_BOARD_DELETE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_PLAN_BEGIN,
                ws_methods::TASK_BOARD_PLAN_BEGIN,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_PLAN_SUBMIT,
                ws_methods::TASK_BOARD_PLAN_SUBMIT,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_PLAN_APPROVE,
                ws_methods::TASK_BOARD_PLAN_APPROVE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_PLAN_REVOKE,
                ws_methods::TASK_BOARD_PLAN_REVOKE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_SYNC,
                ws_methods::TASK_BOARD_SYNC,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_DISPATCH,
                ws_methods::TASK_BOARD_DISPATCH,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_EVALUATE,
                ws_methods::TASK_BOARD_EVALUATE,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_AUDIT,
                ws_methods::TASK_BOARD_AUDIT,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_PROJECTS,
                ws_methods::TASK_BOARD_PROJECTS,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_MACHINES,
                ws_methods::TASK_BOARD_MACHINES,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_HOST_LOCAL,
                ws_methods::TASK_BOARD_HOST_LOCAL,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_HOST_LIST,
                ws_methods::TASK_BOARD_HOST_LIST,
                true,
            ),
            (
                HttpRouteMethod::Put,
                http_paths::TASK_BOARD_HOST_SET_PROJECT_TYPES,
                ws_methods::TASK_BOARD_HOST_SET_PROJECT_TYPES,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_ORCHESTRATOR_STATUS,
                ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_ORCHESTRATOR_START,
                ws_methods::TASK_BOARD_ORCHESTRATOR_START,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_ORCHESTRATOR_STOP,
                ws_methods::TASK_BOARD_ORCHESTRATOR_STOP,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
                ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
                ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_GET,
                true,
            ),
            (
                HttpRouteMethod::Put,
                http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
                ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG,
                ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET,
                true,
            ),
            (
                HttpRouteMethod::Put,
                http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG,
                ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE,
                true,
            ),
            (
                HttpRouteMethod::Put,
                http_paths::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS,
                ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC,
                true,
            ),
            (
                HttpRouteMethod::Put,
                http_paths::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN,
                ws_methods::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
                ws_methods::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_POLICY_PIPELINE,
                ws_methods::TASK_BOARD_POLICY_PIPELINE_GET,
                true,
            ),
            (
                HttpRouteMethod::Put,
                http_paths::TASK_BOARD_POLICY_PIPELINE,
                ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_POLICY_SIMULATE,
                ws_methods::TASK_BOARD_POLICY_PIPELINE_SIMULATE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_POLICY_PROMOTE,
                ws_methods::TASK_BOARD_POLICY_PIPELINE_PROMOTE,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_POLICY_AUDIT,
                ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT,
                true,
            ),
        ]
    );
    let expected_mcp_methods: Vec<_> = actual
        .iter()
        .map(|(_, _, ws_method, _)| *ws_method)
        .collect();
    assert_eq!(task_board_mcp_methods(), expected_mcp_methods);
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
