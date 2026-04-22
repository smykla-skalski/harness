use std::fs;

use super::support::{dashboard_json_paths, load_dashboard, panel_by_title, panel_expr, panel_exprs, repo_root};

#[test]
fn observability_dashboards_are_stable_v2_resources() {
    let dashboards_root = repo_root().join("resources/observability/grafana/dashboards");

    for path in dashboard_json_paths(&dashboards_root) {
        let content = fs::read_to_string(&path).unwrap();
        let dashboard: serde_json::Value = serde_json::from_str(&content).unwrap();
        let file_name = path.file_name().unwrap().to_string_lossy();

        assert_eq!(
            dashboard["apiVersion"].as_str(),
            Some("dashboard.grafana.app/v2"),
            "{file_name} should use the stable Grafana v2 dashboard resource format"
        );
        assert_eq!(
            dashboard["kind"].as_str(),
            Some("Dashboard"),
            "{file_name} should declare a Dashboard resource"
        );
        assert!(
            dashboard["metadata"]["name"]
                .as_str()
                .is_some_and(|name| !name.is_empty()),
            "{file_name} should declare a stable metadata.name"
        );
        assert!(
            dashboard["spec"]["elements"]
                .as_object()
                .is_some_and(|elements| !elements.is_empty()),
            "{file_name} should keep concrete v2 dashboard elements"
        );
        assert!(
            dashboard["spec"]["layout"]["kind"].as_str().is_some(),
            "{file_name} should keep a concrete v2 layout kind"
        );
    }
}

#[test]
fn observability_suite_does_not_reference_removed_monitor_view_performance_dashboard() {
    let dashboards_root = repo_root().join("resources/observability/grafana/dashboards");
    let removed_dashboard = dashboards_root.join("monitor-view-performance.json");
    assert!(
        !removed_dashboard.exists(),
        "removed dashboard should stay absent at {}",
        removed_dashboard.display()
    );

    for path in dashboard_json_paths(&dashboards_root) {
        let content = fs::read_to_string(&path).unwrap();
        assert!(
            !content.contains("harness-monitor-view-performance"),
            "{} should not reference the removed Harness Monitor View Performance dashboard",
            path.display()
        );
    }
}

#[test]
fn monitor_dashboard_surfaces_resource_activity_gauges() {
    let dashboard = load_dashboard("monitor-client.json");

    for (title, metric) in [
        ("Active Tasks", "sum(harness_monitor_active_tasks)"),
        (
            "WS Connections",
            "sum(harness_monitor_websocket_connections)",
        ),
        (
            "Resident Memory",
            "sum(harness_monitor_memory_resident_bytes)",
        ),
        (
            "Virtual Memory",
            "sum(harness_monitor_memory_virtual_bytes)",
        ),
    ] {
        let expr = panel_expr(&dashboard, title);
        assert!(
            expr.contains(metric),
            "{title} should visualize {metric}, got: {expr}"
        );
    }
}

#[test]
fn monitor_dashboard_surfaces_phase1_observability_metrics() {
    let dashboard = load_dashboard("monitor-client.json");

    for (title, metric_fragment) in [
        (
            "Lifecycle Events / 5m",
            "harness_monitor_app_lifecycle_total",
        ),
        (
            "Lifecycle Events / 5m",
            "harness_monitor_user_interactions_total",
        ),
        (
            "Bootstrap p95",
            "harness_monitor_bootstrap_duration_ms_bucket",
        ),
        (
            "Interaction p95",
            "harness_monitor_user_interaction_duration_ms_bucket",
        ),
        ("Cache and API Pressure", "harness_monitor_api_errors_total"),
        (
            "Cache and API Pressure",
            "harness_monitor_cache_read_duration_ms_bucket",
        ),
        ("API Errors / 5m", "harness_monitor_api_errors_total"),
        (
            "Decoding Errors / 5m",
            "harness_monitor_decoding_errors_total",
        ),
        (
            "Timeout Errors / 5m",
            "harness_monitor_timeout_errors_total",
        ),
        (
            "User Interactions / 5m",
            "harness_monitor_user_interactions_total",
        ),
        ("Cache Miss %", "harness_monitor_cache_misses_total"),
    ] {
        let exprs = panel_exprs(&dashboard, title);
        assert!(
            exprs.iter().any(|expr| expr.contains(metric_fragment)),
            "{title} should visualize {metric_fragment}, got: {exprs:?}"
        );
    }
}

#[test]
fn monitor_dashboard_stat_panels_handle_short_lived_clients() {
    let dashboard = load_dashboard("monitor-client.json");

    for title in ["Lifecycle Events / 5m", "Cache and API Pressure"] {
        for expr in panel_exprs(&dashboard, title) {
            assert!(
                expr.contains("last_over_time("),
                "{title} should tolerate short-lived monitor clients with a last_over_time fallback, got: {expr}"
            );
        }
    }

    for title in [
        "Bootstrap p95",
        "Interaction p95",
        "Cache Miss %",
        "API Errors / 5m",
        "Decoding Errors / 5m",
        "Timeout Errors / 5m",
        "User Interactions / 5m",
    ] {
        let expr = panel_expr(&dashboard, title);
        assert!(
            expr.contains("last_over_time("),
            "{title} should tolerate short-lived monitor clients with a last_over_time fallback, got: {expr}"
        );
    }
}

#[test]
fn monitor_dashboard_lifecycle_panel_uses_exported_label_names() {
    let dashboard = load_dashboard("monitor-client.json");
    let lifecycle_panel = panel_by_title(&dashboard, "Lifecycle Events / 5m");
    let legend = lifecycle_panel["targets"]
        .as_array()
        .and_then(|targets| targets.first())
        .and_then(|target| target["legendFormat"].as_str())
        .unwrap_or_else(|| panic!("missing lifecycle legend format"));

    assert_eq!(
        legend, "{{app_lifecycle_event}}",
        "Lifecycle Events / 5m should use the exported Prometheus label name"
    );
}
