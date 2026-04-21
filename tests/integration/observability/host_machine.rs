use super::support::{load_dashboard, load_yaml_file, panel_expr, panel_exprs};

#[test]
fn host_machine_dashboard_uses_auto_grid_and_surfaces_host_and_process_views() {
    let dashboard = load_dashboard("host-machine.json");

    assert_eq!(dashboard["layout"]["kind"].as_str(), Some("auto-grid"));
    assert_eq!(
        dashboard["layout"]["spec"]["maxColumnCount"].as_i64(),
        Some(4)
    );
    assert_eq!(
        dashboard["layout"]["spec"]["columnWidthMode"].as_str(),
        Some("custom")
    );
    assert_eq!(
        dashboard["layout"]["spec"]["columnWidth"].as_i64(),
        Some(300)
    );

    for (title, metric_fragment) in [
        (
            "Network I/O by Interface",
            "node_network_receive_bytes_total",
        ),
        (
            "Network I/O by Interface",
            "node_network_transmit_bytes_total",
        ),
        ("Process States", "system_processes_count"),
        ("Tracked Process CPU", "process_cpu_utilization_ratio"),
        ("Tracked Process RSS", "process_memory_usage_bytes"),
        (
            "Tracked Process Virtual Memory",
            "process_memory_virtual_bytes",
        ),
        ("Tracked Process Threads", "process_threads"),
        ("Tracked Process Open FDs", "process_open_file_descriptors"),
        ("Tracked Process Uptime", "process_uptime_seconds"),
    ] {
        let exprs = panel_exprs(&dashboard, title);
        assert!(
            exprs.iter().any(|expr| expr.contains(metric_fragment)),
            "{title} should visualize {metric_fragment}, got: {exprs:?}"
        );
    }
}

#[test]
fn host_machine_dashboard_process_queries_do_not_reintroduce_high_cardinality_pid_labels() {
    let dashboard = load_dashboard("host-machine.json");

    for title in [
        "Tracked Process CPU",
        "Tracked Process RSS",
        "Tracked Process Virtual Memory",
        "Tracked Process Threads",
        "Tracked Process Open FDs",
        "Tracked Process Uptime",
    ] {
        for expr in panel_exprs(&dashboard, title) {
            assert!(
                !expr.contains("process_pid"),
                "{title} should not key queries by PID labels, got: {expr}"
            );
            assert!(
                !expr.contains("process_command_line"),
                "{title} should not depend on command-line labels, got: {expr}"
            );
            assert!(
                expr.contains("process_executable_name"),
                "{title} should aggregate by executable name, got: {expr}"
            );
        }
    }
}

#[test]
fn prometheus_scrapes_the_host_process_exporter_endpoint() {
    let config: serde_yml::Value =
        load_yaml_file("resources/observability/prometheus/prometheus.yml");
    let scrape_configs = config["scrape_configs"]
        .as_sequence()
        .expect("prometheus.yml should declare scrape_configs");
    let process_job = scrape_configs
        .iter()
        .find(|job| job["job_name"].as_str() == Some("alloy-host-processes"))
        .expect("prometheus should scrape the host process exporter");
    let targets = process_job["static_configs"][0]["targets"]
        .as_sequence()
        .expect("alloy-host-processes should declare a target list");

    assert!(
        targets
            .iter()
            .any(|target| target.as_str() == Some("host.docker.internal:10103")),
        "alloy-host-processes should scrape the repo-managed host process exporter on port 10103, got: {targets:?}"
    );
}

#[test]
fn process_state_panel_breaks_down_status_counts() {
    let dashboard = load_dashboard("host-machine.json");
    let expr = panel_expr(&dashboard, "Process States");

    assert!(
        expr.contains("sum by (status)"),
        "Process States should break counts down by status, got: {expr}"
    );
}
