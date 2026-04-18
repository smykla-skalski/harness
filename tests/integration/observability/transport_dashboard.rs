use super::support::{load_dashboard, panel_expr};

#[test]
fn daemon_transport_dashboard_surfaces_sparse_client_activity_as_cumulative_usage() {
    let dashboard = load_dashboard("daemon-transport.json");

    let request_total = panel_expr(&dashboard, "Client Requests");
    assert!(
        request_total.contains("last_over_time(harness_daemon_client_requests_total")
            && request_total.contains("[$__range])"),
        "Client Requests should surface the cumulative client counter over the visible range, got: {request_total}"
    );
    assert!(
        !request_total.contains("/ 300"),
        "Client Requests should not dilute sparse traffic into a per-second rate, got: {request_total}"
    );

    let latency_total = panel_expr(&dashboard, "Client p95 (cumulative)");
    assert!(
        latency_total.contains("last_over_time(harness_daemon_client_duration_milliseconds_bucket"),
        "Client p95 (cumulative) should surface the cumulative client histogram, got: {latency_total}"
    );
    assert!(
        latency_total.contains("[$__range])"),
        "Client p95 (cumulative) should use the visible dashboard range, got: {latency_total}"
    );
    assert!(
        !latency_total.contains("offset 5m"),
        "Client p95 (cumulative) should not depend on short 5m deltas, got: {latency_total}"
    );

    let request_breakdown = panel_expr(&dashboard, "Client Requests by Route and Status");
    assert!(
        request_breakdown.contains("last_over_time(harness_daemon_client_requests_total"),
        "Client Requests by Route and Status should surface cumulative client totals, got: {request_breakdown}"
    );
    assert!(
        request_breakdown.contains("http_route=~\"${http_route:regex}\"")
            && request_breakdown.contains("http_status_code=~\"${http_status_code:regex}\"")
            && request_breakdown.contains("[$__range])"),
        "Client Requests by Route and Status should keep the route/status filters over the visible range, got: {request_breakdown}"
    );
    assert!(
        !request_breakdown.contains("/ 300"),
        "Client Requests by Route and Status should not dilute sparse traffic into a per-second rate, got: {request_breakdown}"
    );
}
