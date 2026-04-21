use super::support::{load_dashboard, panel_by_title, panel_expr, panel_exprs};

fn dashboard_link_urls(dashboard: &serde_json::Value) -> Vec<&str> {
    dashboard["links"]
        .as_array()
        .expect("dashboard should declare links")
        .iter()
        .filter_map(|link| link["url"].as_str())
        .collect()
}

#[test]
fn host_process_dashboard_uses_responsive_panel_widths_and_scoped_process_filters() {
    let dashboard = load_dashboard("host-processes.json");

    assert_eq!(
        dashboard["timepicker"]["refresh_intervals"]
            .as_array()
            .map(Vec::len),
        Some(10),
        "host process dashboard should expose modern refresh interval shortcuts"
    );
    assert_eq!(
        dashboard["timepicker"]["quick_ranges"]
            .as_array()
            .map(Vec::len),
        Some(5),
        "host process dashboard should expose quick time range shortcuts"
    );

    for title in [
        "Tracked Process Groups",
        "Running Processes",
        "Sleeping Processes",
        "Zombie Processes",
        "Process State Share",
        "Process States Over Time",
        "Process CPU by Name",
        "Top CPU Now",
        "Top RSS Now",
    ] {
        let width = panel_by_title(&dashboard, title)["gridPos"]["w"].as_i64();
        assert!(
            matches!(width, Some(6 | 12)),
            "{title} should use a responsive quarter-width or half-width layout, got: {width:?}"
        );
    }

    let process_variable = dashboard["templating"]["list"]
        .as_array()
        .expect("host process dashboard should declare templating variables")
        .iter()
        .find(|variable| variable["name"].as_str() == Some("process_name"))
        .expect("host process dashboard should expose a process_name variable");
    assert_eq!(process_variable["type"].as_str(), Some("query"));
    assert!(
        process_variable["query"]
            .as_str()
            .expect("process_name should have a query")
            .contains("label_values(process_cpu_utilization_ratio, process_executable_name)"),
        "process_name variable should enumerate tracked executable names"
    );

    for (title, metric_fragment) in [
        ("Tracked Process Groups", "process_cpu_utilization_ratio"),
        (
            "Running Processes",
            "system_processes_count{status=\"running\"}",
        ),
        (
            "Zombie Processes",
            "system_processes_count{status=\"zombies\"}",
        ),
        ("Process State Share", "system_processes_count"),
        ("Top CPU Process", "process_cpu_utilization_ratio"),
        ("Top RSS Process", "process_memory_usage_bytes"),
        ("Process States Over Time", "system_processes_count"),
        ("Process CPU by Name", "process_cpu_utilization_ratio"),
        ("Process RSS by Name", "process_memory_usage_bytes"),
        (
            "Process Virtual Memory by Name",
            "process_memory_virtual_bytes",
        ),
        ("Process Threads by Name", "process_threads"),
        ("Process Open FDs by Name", "process_open_file_descriptors"),
        ("Process Uptime by Name", "process_uptime_seconds"),
        ("Top CPU Now", "process_cpu_utilization_ratio"),
        ("Top RSS Now", "process_memory_usage_bytes"),
        ("Top Threads Now", "process_threads"),
        ("Top Open FDs Now", "process_open_file_descriptors"),
    ] {
        let exprs = panel_exprs(&dashboard, title);
        assert!(
            exprs.iter().any(|expr| expr.contains(metric_fragment)),
            "{title} should visualize {metric_fragment}, got: {exprs:?}"
        );
    }

    assert_eq!(
        panel_by_title(&dashboard, "Process State Share")["type"].as_str(),
        Some("piechart"),
        "host process dashboard should use a pie/donut summary for process-state share"
    );

    let cpu_legend = &panel_by_title(&dashboard, "Process CPU by Name")["options"]["legend"];
    assert_eq!(cpu_legend["displayMode"].as_str(), Some("table"));
    assert!(
        cpu_legend["calcs"].as_array().is_some_and(|calcs| calcs
            .iter()
            .any(|calc| calc.as_str() == Some("lastNotNull"))),
        "Process CPU by Name should expose legend calculations"
    );
}

#[test]
fn host_process_dashboard_queries_stay_low_cardinality() {
    let dashboard = load_dashboard("host-processes.json");

    for title in [
        "Top CPU Process",
        "Top RSS Process",
        "Process CPU by Name",
        "Process RSS by Name",
        "Process Virtual Memory by Name",
        "Process Threads by Name",
        "Process Open FDs by Name",
        "Process Uptime by Name",
        "Top CPU Now",
        "Top RSS Now",
        "Top Threads Now",
        "Top Open FDs Now",
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
fn host_process_dashboard_links_back_to_the_main_investigation_surfaces() {
    let dashboard = load_dashboard("host-processes.json");
    let urls = dashboard_link_urls(&dashboard);

    for expected in [
        "/d/harness-investigation-cockpit",
        "/d/harness-host-machine",
        "/a/grafana-metricsdrilldown-app/drilldown",
        "/a/grafana-lokiexplore-app/explore",
    ] {
        assert!(
            urls.iter().any(|url| url == &expected),
            "host process dashboard should link to {expected}, got: {urls:?}"
        );
    }

    let ranking_links = panel_by_title(&dashboard, "Top CPU Now")["links"]
        .as_array()
        .expect("Top CPU Now should declare panel links");
    assert!(
        ranking_links
            .iter()
            .filter_map(|link| link["url"].as_str())
            .any(|url| url == "/a/grafana-metricsdrilldown-app/drilldown"),
        "Top CPU Now should offer a direct path into Metrics Drilldown"
    );
}

#[test]
fn investigation_cockpit_uses_responsive_panel_widths_and_links_to_process_drilldown() {
    let dashboard = load_dashboard("investigation-cockpit.json");

    assert_eq!(
        dashboard["timepicker"]["refresh_intervals"]
            .as_array()
            .map(Vec::len),
        Some(10),
        "investigation cockpit should expose modern refresh interval shortcuts"
    );

    for title in [
        "Hook p95",
        "Running Processes",
        "Top CPU Process",
        "Host Stress Correlation",
        "Top Tracked Process CPU",
        "Top Slow Routes",
    ] {
        let width = panel_by_title(&dashboard, title)["gridPos"]["w"].as_i64();
        assert!(
            matches!(width, Some(6 | 12)),
            "{title} should use a responsive quarter-width or half-width layout, got: {width:?}"
        );
    }

    let urls = dashboard_link_urls(&dashboard);
    assert!(
        urls.iter().any(|url| url == &"/d/harness-host-processes"),
        "investigation cockpit should link to the host process drilldown, got: {urls:?}"
    );

    for (title, metric_fragment) in [
        (
            "Running Processes",
            "system_processes_count{status=\"running\"}",
        ),
        (
            "Zombie Processes",
            "system_processes_count{status=\"zombies\"}",
        ),
        ("Top CPU Process", "process_cpu_utilization_ratio"),
        ("Top RSS Process", "process_memory_usage_bytes"),
    ] {
        let expr = panel_expr(&dashboard, title);
        assert!(
            expr.contains(metric_fragment),
            "{title} should use {metric_fragment}, got: {expr}"
        );
    }

    let cpu_legend = &panel_by_title(&dashboard, "Top Tracked Process CPU")["options"]["legend"];
    assert!(
        cpu_legend["calcs"]
            .as_array()
            .is_some_and(|calcs| calcs.iter().any(|calc| calc.as_str() == Some("max"))),
        "Top Tracked Process CPU should expose legend calculations for quick ranking"
    );
}
