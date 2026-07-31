use super::*;
use crate::daemon::remote::{RemoteAccessScope, remote_http_scopes, remote_ws_scopes};

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
fn every_http_route_has_remote_scope_contract() {
    for route in HTTP_API_CONTRACT.iter() {
        // The one deliberate exception: this route must never be
        // remote-authorizable at all (see
        // `task_board_triage_escalation_verdict_route_is_never_remote_authorizable`
        // below) -- declaring any scope here would make
        // `authorize_remote_http_route` accept it from a remote client,
        // exactly what it must never do.
        if route.path == http_paths::TASK_BOARD_TRIAGE_ESCALATION_VERDICT {
            continue;
        }
        assert!(
            remote_http_scopes(route).is_some(),
            "{} {} should declare remote auth scopes",
            route.method.as_str(),
            route.path
        );
    }
}

#[test]
fn task_board_triage_escalation_verdict_route_is_never_remote_authorizable() {
    let route = HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == http_paths::TASK_BOARD_TRIAGE_ESCALATION_VERDICT)
        .expect("triage escalation verdict route should be registered");

    assert!(matches!(route.parity, HttpRouteParity::Exempt { .. }));
    assert!(route.parity.ws_method().is_none());
    assert!(!route.swift_client_exposed);
    assert_eq!(
        remote_http_scopes(route),
        None,
        "no remote scope contract means authorize_remote_http_route fails closed \
         with MissingScopeContract for any remote caller"
    );
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
fn task_board_sync_control_has_remote_surface_scopes() {
    let route_scope = |method, path| {
        let route = HTTP_API_CONTRACT
            .iter()
            .find(|route| route.method == method && route.path == path)
            .unwrap_or_else(|| panic!("missing task-board sync route {method:?} {path}"));
        remote_http_scopes(route)
    };

    assert_eq!(
        route_scope(HttpRouteMethod::Post, http_paths::TASK_BOARD_SYNC_CANCEL),
        Some(&[RemoteAccessScope::Write][..])
    );
    assert_eq!(
        route_scope(HttpRouteMethod::Get, http_paths::TASK_BOARD_SYNC_STATUS),
        Some(&[RemoteAccessScope::Read][..])
    );
    assert_eq!(
        remote_ws_scopes(ws_methods::TASK_BOARD_SYNC_CANCEL),
        Some(&[RemoteAccessScope::Write][..])
    );
    assert_eq!(
        remote_ws_scopes(ws_methods::TASK_BOARD_SYNC_STATUS),
        Some(&[RemoteAccessScope::Read][..])
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
