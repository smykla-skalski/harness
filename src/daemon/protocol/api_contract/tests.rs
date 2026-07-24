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
    assert_eq!(exemptions.len(), 15, "unexpected exemption count");
    let exempt_paths: BTreeSet<_> = exemptions.iter().map(|route| route.path).collect();
    assert_eq!(
        exempt_paths,
        BTreeSet::from([
            http_paths::DAEMON_TELEMETRY,
            http_paths::REMOTE_PAIR_CLAIM,
            http_paths::REMOTE_PAIR_STATUS,
            http_paths::REMOTE_CLIENT_SELF_REVOKE,
            http_paths::POLICIES_DUMP,
            http_paths::POLICIES_IMPORT,
            http_paths::WS,
            http_paths::STREAM,
            http_paths::SESSION_STREAM,
            http_paths::READY,
            http_paths::MANAGED_AGENT_ATTACH,
            http_paths::MANAGED_AGENT_ACP_LOGOUT,
            http_paths::MANAGED_AGENT_ACP_SESSIONS,
            http_paths::MANAGED_AGENT_ACP_SESSION_DELETE,
            http_paths::MANAGED_AGENT_ACP_SESSION_CLOSE,
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
fn policy_transfer_routes_have_remote_read_write_scopes() {
    let scope_for = |path| {
        let route = HTTP_API_CONTRACT
            .iter()
            .find(|route| route.path == path)
            .unwrap_or_else(|| panic!("missing policy transfer route {path}"));
        remote_http_scopes(route)
    };

    assert_eq!(
        scope_for(http_paths::POLICIES_DUMP),
        Some(&[RemoteAccessScope::Read][..])
    );
    assert_eq!(
        scope_for(http_paths::POLICIES_IMPORT),
        Some(&[RemoteAccessScope::Write][..])
    );
}

#[test]
fn remote_client_self_revoke_is_a_read_scoped_swift_exemption() {
    let route = HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == http_paths::REMOTE_CLIENT_SELF_REVOKE)
        .expect("remote client self-revoke route should be registered");

    assert_eq!(route.method, HttpRouteMethod::Post);
    assert!(route.swift_client_exposed);
    assert!(route.parity.exemption_reason().is_some());
    assert_eq!(
        remote_http_scopes(route),
        Some(&[RemoteAccessScope::Read][..])
    );
}

#[test]
fn remote_pair_status_route_is_public_exemption_with_scope() {
    let route = HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == http_paths::REMOTE_PAIR_STATUS)
        .expect("remote pair status route should be registered");

    assert_eq!(route.method, HttpRouteMethod::Post);
    assert!(!route.swift_client_exposed);
    assert!(route.parity.exemption_reason().is_some());
    assert_eq!(
        remote_http_scopes(route),
        Some(&[RemoteAccessScope::Read][..])
    );
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
fn database_task_board_methods_have_remote_scope_contract() {
    for method in [
        ws_methods::TASK_BOARD_CAPABILITIES,
        ws_methods::TASK_BOARD_GIT_RUNTIME_KEY_MATERIAL_SYNC,
        ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE,
        ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_ACK,
    ] {
        assert!(
            ws_methods::ALL.contains(&method),
            "{method} should be listed in ws_methods::ALL"
        );
        assert!(
            remote_ws_scopes(method).is_some(),
            "{method} should declare remote auth scopes"
        );
    }
}

#[test]
fn manual_dispatch_steps_have_remote_surface_scopes() {
    assert_eq!(
        remote_ws_scopes(ws_methods::TASK_BOARD_DISPATCH_PICK),
        Some(&[RemoteAccessScope::Read][..])
    );
    assert_eq!(
        remote_ws_scopes(ws_methods::TASK_BOARD_DISPATCH_DELIVER),
        Some(&[RemoteAccessScope::Write][..])
    );
}

#[test]
fn policy_approval_grant_revoke_requires_remote_write_scope() {
    let route = HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == http_paths::POLICY_APPROVAL_GRANT_REVOKE)
        .expect("policy approval grant revoke route should be registered");

    assert_eq!(
        remote_http_scopes(route),
        Some(&[RemoteAccessScope::Write][..])
    );
    assert_eq!(
        remote_ws_scopes(ws_methods::POLICY_APPROVAL_GRANT_REVOKE),
        Some(&[RemoteAccessScope::Write][..])
    );
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
fn task_board_position_remote_scopes_keep_viewers_read_only() {
    let route_scope = |method, path| {
        let route = HTTP_API_CONTRACT
            .iter()
            .find(|route| route.method == method && route.path == path)
            .unwrap_or_else(|| panic!("missing task-board position route {method:?} {path}"));
        remote_http_scopes(route)
    };

    assert_eq!(
        route_scope(HttpRouteMethod::Get, http_paths::TASK_BOARD_ITEM_POSITION),
        Some(&[RemoteAccessScope::Read][..])
    );
    assert_eq!(
        route_scope(HttpRouteMethod::Put, http_paths::TASK_BOARD_ITEM_POSITION),
        Some(&[RemoteAccessScope::Write][..])
    );
    assert_eq!(
        route_scope(
            HttpRouteMethod::Post,
            http_paths::TASK_BOARD_ITEM_POSITION_RESET
        ),
        Some(&[RemoteAccessScope::Write][..])
    );
    assert_eq!(
        remote_ws_scopes(ws_methods::TASK_BOARD_POSITION_GET),
        Some(&[RemoteAccessScope::Read][..])
    );
    assert_eq!(
        remote_ws_scopes(ws_methods::TASK_BOARD_POSITION_SET),
        Some(&[RemoteAccessScope::Write][..])
    );
    assert_eq!(
        remote_ws_scopes(ws_methods::TASK_BOARD_POSITION_RESET),
        Some(&[RemoteAccessScope::Write][..])
    );
}

#[test]
fn task_board_triage_remote_scopes_are_read_only() {
    let route_scope = |method, path| {
        let route = HTTP_API_CONTRACT
            .iter()
            .find(|route| route.method == method && route.path == path)
            .unwrap_or_else(|| panic!("missing task-board triage route {method:?} {path}"));
        remote_http_scopes(route)
    };

    assert_eq!(
        route_scope(HttpRouteMethod::Get, http_paths::TASK_BOARD_ITEM_TRIAGE),
        Some(&[RemoteAccessScope::Read][..])
    );
    assert_eq!(
        route_scope(
            HttpRouteMethod::Get,
            http_paths::TASK_BOARD_ITEM_TRIAGE_HISTORY
        ),
        Some(&[RemoteAccessScope::Read][..])
    );
    assert_eq!(
        remote_ws_scopes(ws_methods::TASK_BOARD_TRIAGE_GET),
        Some(&[RemoteAccessScope::Read][..])
    );
    assert_eq!(
        remote_ws_scopes(ws_methods::TASK_BOARD_TRIAGE_HISTORY),
        Some(&[RemoteAccessScope::Read][..])
    );
}

#[test]
fn task_board_triage_override_mutations_require_remote_write_scope() {
    let route_scope = |method, path| {
        let route = HTTP_API_CONTRACT
            .iter()
            .find(|route| route.method == method && route.path == path)
            .unwrap_or_else(|| {
                panic!("missing task-board triage override route {method:?} {path}")
            });
        remote_http_scopes(route)
    };

    assert_eq!(
        route_scope(
            HttpRouteMethod::Put,
            http_paths::TASK_BOARD_ITEM_TRIAGE_OVERRIDE
        ),
        Some(&[RemoteAccessScope::Write][..])
    );
    assert_eq!(
        route_scope(
            HttpRouteMethod::Post,
            http_paths::TASK_BOARD_ITEM_TRIAGE_OVERRIDE_CLEAR
        ),
        Some(&[RemoteAccessScope::Write][..])
    );
    assert_eq!(
        remote_ws_scopes(ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_SET),
        Some(&[RemoteAccessScope::Write][..])
    );
    assert_eq!(
        remote_ws_scopes(ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_CLEAR),
        Some(&[RemoteAccessScope::Write][..])
    );
    let viewer_scopes =
        crate::daemon::remote::scopes_for_role(crate::daemon::remote::RemoteRole::Viewer);
    assert!(!viewer_scopes.contains(&RemoteAccessScope::Write));
}

#[test]
fn reviews_pull_request_resolve_remote_scope_is_read_only() {
    let route = HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == http_paths::REVIEWS_PULL_REQUEST_RESOLVE)
        .expect("reviews pull request resolve route should be registered");

    assert_eq!(
        remote_http_scopes(route),
        Some(&[RemoteAccessScope::Read][..])
    );
    assert_eq!(
        remote_ws_scopes(ws_methods::REVIEWS_PULL_REQUEST_RESOLVE),
        Some(&[RemoteAccessScope::Read][..])
    );
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
fn github_status_route_is_swift_exposed_rpc() {
    let route = HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == http_paths::GITHUB_STATUS)
        .expect("github status route should be registered");
    assert_eq!(route.method, HttpRouteMethod::Get);
    assert!(route.swift_client_exposed);
    match route.parity {
        HttpRouteParity::Rpc { ws_method } => assert_eq!(ws_method, ws_methods::GITHUB_STATUS),
        HttpRouteParity::Exempt { .. } => panic!("github status route must use websocket parity"),
    }
}

/// WebSocket methods in [`ws_methods::ALL`] that intentionally have no HTTP
/// route - socket-only subscription and keepalive primitives. Every other
/// declared method must map to a route; an unmapped method is almost always a
/// missing route contract, as `github.status` and `task.delete` both were.
const WS_ONLY_METHODS: &[&str] = &[
    ws_methods::PING,
    ws_methods::SESSION_SUBSCRIBE,
    ws_methods::SESSION_UNSUBSCRIBE,
    ws_methods::STREAM_SUBSCRIBE,
    ws_methods::STREAM_UNSUBSCRIBE,
];

#[test]
fn every_declared_ws_method_maps_to_a_route_or_is_ws_only() {
    let mapped: BTreeSet<&str> = mapped_ws_methods().into_iter().collect();
    let unmapped: BTreeSet<&str> = ws_methods::ALL
        .iter()
        .copied()
        .filter(|method| !mapped.contains(method))
        .collect();
    let ws_only: BTreeSet<&str> = WS_ONLY_METHODS.iter().copied().collect();
    assert_eq!(
        unmapped, ws_only,
        "every websocket method in ws_methods::ALL must map to an HTTP route or be listed in \
         WS_ONLY_METHODS; an unexpected unmapped method is almost always a missing route contract"
    );
}

mod task_board;

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
