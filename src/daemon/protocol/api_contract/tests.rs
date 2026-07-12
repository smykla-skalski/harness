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
