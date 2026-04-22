use super::*;
use std::collections::BTreeSet;

#[test]
fn every_non_exempt_http_route_has_a_ws_mapping() {
    for route in HTTP_API_CONTRACT {
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
    assert_eq!(exemptions.len(), 5, "unexpected exemption count");
    let exempt_paths: BTreeSet<_> = exemptions.iter().map(|route| route.path).collect();
    assert_eq!(
        exempt_paths,
        BTreeSet::from([
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
fn mapped_ws_methods_are_unique() {
    let methods = mapped_ws_methods();
    let unique: BTreeSet<_> = methods.iter().copied().collect();
    assert_eq!(
        methods.len(),
        unique.len(),
        "duplicate websocket method mapping"
    );
}
