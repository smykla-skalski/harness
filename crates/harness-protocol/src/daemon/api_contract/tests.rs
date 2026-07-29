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
    assert_eq!(exemptions.len(), 17, "unexpected exemption count");
    let exempt_paths: BTreeSet<_> = exemptions.iter().map(|route| route.path).collect();
    assert_eq!(
        exempt_paths,
        BTreeSet::from([
            http_paths::DAEMON_TELEMETRY,
            http_paths::REMOTE_PAIR_CLAIM,
            http_paths::REMOTE_PAIR_STATUS,
            http_paths::REMOTE_PAIR_MINT,
            http_paths::REMOTE_CLIENT_SELF_REVOKE,
            http_paths::REMOTE_PAIRINGS,
            http_paths::REMOTE_PAIRING_REVOKE,
            http_paths::POLICIES_DUMP,
            http_paths::POLICIES_IMPORT,
            http_paths::WS,
            http_paths::REMOTE_WS,
            http_paths::STREAM,
            http_paths::SESSION_STREAM,
            http_paths::READY,
            http_paths::HEADLESS_READINESS,
            http_paths::MANAGED_AGENT_ATTACH,
            http_paths::TASK_BOARD_TRIAGE_ESCALATION_VERDICT,
        ])
    );
}

/// Placeholder-reason guard. Every exemption must be classified structural or a
/// standing decision and must not lean on "no client consumes it yet" wording. A
/// route that merely lacks a client path is a parity gap to close, not an
/// exemption to record, so this stops a future placeholder from passing as a
/// warranted exemption. See `docs/api/websocket-parity-exemptions.md`.
#[test]
fn every_exemption_is_classified_with_a_durable_reason() {
    // Substrings that betray an unbuilt-client placeholder rather than a decision.
    const PROVISIONAL_MARKERS: &[&str] = &[
        "yet",
        "no client",
        "no monitor",
        "not built",
        "unbuilt",
        "for now",
        "provisional",
        "todo",
        "will be",
        "planned",
        "not implemented",
        "consumes it",
        "not consumed",
    ];
    for route in explicit_exemptions() {
        let kind = route
            .parity
            .exemption_kind()
            .expect("exempt route must declare a kind");
        assert!(
            matches!(
                kind,
                WsExemptionKind::Structural | WsExemptionKind::StandingDecision
            ),
            "{} {} must be structural or a standing decision",
            route.method.as_str(),
            route.path
        );
        let reason = route
            .parity
            .exemption_reason()
            .expect("exempt route must carry a reason");
        assert!(
            !reason.trim().is_empty(),
            "{} {} has an empty exemption reason",
            route.method.as_str(),
            route.path
        );
        let lowered = reason.to_ascii_lowercase();
        for marker in PROVISIONAL_MARKERS {
            assert!(
                !lowered.contains(marker),
                "{} {}: exemption reason reads as an unbuilt placeholder (\"{marker}\"); close the \
                 parity gap or record a durable structural / standing-decision reason",
                route.method.as_str(),
                route.path
            );
        }
    }
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
