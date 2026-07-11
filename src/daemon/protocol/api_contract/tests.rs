use super::*;
use crate::daemon::remote::{RemoteAccessScope, remote_http_scopes, remote_ws_scopes};
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
    assert_eq!(exemptions.len(), 7, "unexpected exemption count");
    let exempt_paths: BTreeSet<_> = exemptions.iter().map(|route| route.path).collect();
    assert_eq!(
        exempt_paths,
        BTreeSet::from([
            http_paths::DAEMON_TELEMETRY,
            http_paths::REMOTE_PAIR_CLAIM,
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
fn remote_pair_claim_route_is_public_exemption_with_scope() {
    let route = HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == http_paths::REMOTE_PAIR_CLAIM)
        .expect("remote pair claim route should be registered");

    assert_eq!(route.method, HttpRouteMethod::Post);
    assert!(!route.swift_client_exposed);
    assert!(route.parity.exemption_reason().is_some());
    assert_eq!(
        remote_http_scopes(route),
        Some(&[RemoteAccessScope::Read][..])
    );
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
fn every_http_route_has_remote_scope_contract() {
    for route in HTTP_API_CONTRACT.iter() {
        assert!(
            remote_http_scopes(route).is_some(),
            "{} {} should declare remote auth scopes",
            route.method.as_str(),
            route.path
        );
    }
}

#[test]
fn every_declared_ws_method_has_remote_scope_contract() {
    for method in ws_methods::ALL {
        assert!(
            remote_ws_scopes(method).is_some(),
            "{method} should declare remote auth scopes"
        );
    }
}

#[test]
fn every_mapped_ws_method_is_listed_in_ws_methods_all() {
    let declared_methods: BTreeSet<_> = ws_methods::ALL.iter().copied().collect();

    for method in mapped_ws_methods() {
        assert!(
            declared_methods.contains(method),
            "{method} should be listed in ws_methods::ALL"
        );
    }
}

#[test]
fn remote_viewer_scope_is_read_only() {
    let viewer_scopes =
        crate::daemon::remote::scopes_for_role(crate::daemon::remote::RemoteRole::Viewer);

    assert!(viewer_scopes.contains(&RemoteAccessScope::Read));
    assert!(!viewer_scopes.contains(&RemoteAccessScope::Write));
    assert!(!viewer_scopes.contains(&RemoteAccessScope::Admin));
}

#[test]
fn reviews_files_patch_remote_scope_is_read_only() {
    let scopes = remote_ws_scopes(ws_methods::REVIEWS_FILES_PATCH)
        .expect("reviews files patch should declare remote scopes");

    assert_eq!(scopes, &[RemoteAccessScope::Read]);
}

#[test]
fn audit_events_route_is_swift_exposed_rpc() {
    let route = HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == http_paths::AUDIT_EVENTS)
        .expect("audit events route should be registered");
    assert_eq!(route.method, HttpRouteMethod::Get);
    assert!(route.swift_client_exposed);
    match route.parity {
        HttpRouteParity::Rpc { ws_method } => assert_eq!(ws_method, ws_methods::AUDIT_EVENTS),
        HttpRouteParity::Exempt { .. } => panic!("audit events route must use websocket parity"),
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
                HttpRouteMethod::Put,
                http_paths::TASK_BOARD_ORCHESTRATOR_OPENROUTER_TOKEN,
                ws_methods::TASK_BOARD_ORCHESTRATOR_OPENROUTER_TOKEN_SYNC,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
                ws_methods::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_GIT_SIGNING_VERIFY,
                ws_methods::TASK_BOARD_GIT_SIGNING_VERIFY,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::TASK_BOARD_GIT_RUNTIME_DRAIN_SECRETS,
                ws_methods::TASK_BOARD_GIT_RUNTIME_DRAIN_SECRETS,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::POLICY_CANVASES,
                ws_methods::POLICY_CANVAS_WORKSPACE_GET,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_CANVASES_CREATE,
                ws_methods::POLICY_CANVAS_CREATE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_CANVASES_DUPLICATE,
                ws_methods::POLICY_CANVAS_DUPLICATE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_CANVASES_RENAME,
                ws_methods::POLICY_CANVAS_RENAME,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_CANVASES_ACTIVE,
                ws_methods::POLICY_CANVAS_SET_ACTIVE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_CANVASES_DELETE,
                ws_methods::POLICY_CANVAS_DELETE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_CANVASES_GLOBAL_ENFORCEMENT,
                ws_methods::POLICY_CANVAS_SET_GLOBAL_ENFORCEMENT,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::POLICY_PIPELINE,
                ws_methods::POLICY_PIPELINE_GET,
                true,
            ),
            (
                HttpRouteMethod::Put,
                http_paths::POLICY_PIPELINE,
                ws_methods::POLICY_PIPELINE_SAVE_DRAFT,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_SIMULATE,
                ws_methods::POLICY_PIPELINE_SIMULATE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_PROMOTE,
                ws_methods::POLICY_PIPELINE_PROMOTE,
                true,
            ),
            (
                HttpRouteMethod::Get,
                http_paths::POLICY_AUDIT,
                ws_methods::POLICY_PIPELINE_AUDIT,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_CANVAS_EXPORT,
                ws_methods::POLICY_CANVAS_EXPORT,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_CANVAS_IMPORT,
                ws_methods::POLICY_CANVAS_IMPORT,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_SCENARIOS_CREATE,
                ws_methods::POLICY_SCENARIO_CREATE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_SCENARIOS_UPDATE,
                ws_methods::POLICY_SCENARIO_UPDATE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_SCENARIOS_DELETE,
                ws_methods::POLICY_SCENARIO_DELETE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_SCENARIOS_RESET,
                ws_methods::POLICY_SCENARIO_RESET,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_MAKE_LIVE,
                ws_methods::POLICY_PIPELINE_MAKE_LIVE,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_GO_LIVE_DIFF,
                ws_methods::POLICY_PIPELINE_GO_LIVE_DIFF,
                true,
            ),
            (
                HttpRouteMethod::Post,
                http_paths::POLICY_REPLAY,
                ws_methods::POLICY_PIPELINE_REPLAY,
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
