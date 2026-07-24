use super::*;

#[path = "task_board_ws_parity_expected.rs"]
mod task_board_ws_parity_expected;

#[test]
fn task_board_routes_have_complete_ws_parity() {
    let actual: Vec<_> = super::routes_task_board::ROUTES
        .iter()
        .chain(super::routes_task_board_working_copies::ROUTES)
        .chain(super::routes_task_board_positions::ROUTES)
        .chain(super::routes_task_board_triage::ROUTES)
        .chain(super::routes_task_board_orchestrator::ROUTES)
        // The triage escalation verdict route is the one deliberate
        // exception (see `task_board_triage_escalation_verdict_route_is_never_remote_authorizable`):
        // HTTP-only by design, no websocket mapping exists or should exist.
        .filter(|route| !matches!(route.parity, HttpRouteParity::Exempt { .. }))
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
        task_board_ws_parity_expected::expected_task_board_ws_parity()
    );
    let expected_mcp_methods: Vec<_> = super::routes_task_board::ROUTES
        .iter()
        .chain(super::routes_task_board_positions::ROUTES)
        .chain(super::routes_task_board_triage::ROUTES)
        .filter(|route| !matches!(route.parity, HttpRouteParity::Exempt { .. }))
        .map(|route| {
            route
                .parity
                .ws_method()
                .expect("task-board route should map to websocket")
        })
        .collect();
    assert_eq!(task_board_mcp_methods(), expected_mcp_methods);
}
