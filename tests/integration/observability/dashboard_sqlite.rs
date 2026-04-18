use super::support::{assert_sqlite_table_panel, load_dashboard, panel_expr, panel_exprs};

#[test]
fn sqlite_exporter_query_health_panel_uses_exporter_counter_metric() {
    let dashboard = load_dashboard("sqlite-forensics.json");
    let expr = panel_expr(&dashboard, "SQLite Exporter Query Health");

    assert!(
        expr.contains("queries_total"),
        "SQLite Exporter Query Health should use the sqlite-exporter counter metric, got: {expr}"
    );
    assert!(
        !expr.contains("rate(queries{"),
        "SQLite Exporter Query Health should not query the nonexistent `queries` metric: {expr}"
    );
}

#[test]
fn sqlite_forensics_dashboard_includes_daemon_sqlite_tables() {
    let dashboard = load_dashboard("sqlite-forensics.json");

    assert_sqlite_table_panel(
        &dashboard,
        "Recent Daemon Sessions",
        "sqlite-daemon",
        &[
            "FROM sessions",
            "ORDER BY COALESCE(last_activity_at, updated_at) DESC",
            "LIMIT 20",
        ],
    );
    assert_sqlite_table_panel(
        &dashboard,
        "Daemon Open Tasks",
        "sqlite-daemon",
        &[
            "FROM tasks",
            "WHERE status != 'done'",
            "CASE severity",
            "LIMIT 20",
        ],
    );
    assert_sqlite_table_panel(
        &dashboard,
        "Daemon Event Log",
        "sqlite-daemon",
        &[
            "FROM daemon_events",
            "ORDER BY recorded_at DESC",
            "LIMIT 50",
        ],
    );
}

#[test]
fn sqlite_forensics_dashboard_includes_monitor_sqlite_tables() {
    let dashboard = load_dashboard("sqlite-forensics.json");

    assert_sqlite_table_panel(
        &dashboard,
        "Monitor Cache Freshness",
        "sqlite-monitor",
        &[
            "FROM ZCACHEDSESSION",
            "datetime(ZLASTCACHEDAT + 978307200, 'unixepoch')",
            "ORDER BY ZLASTCACHEDAT DESC",
            "LIMIT 20",
        ],
    );
    assert_sqlite_table_panel(
        &dashboard,
        "Cached Work Items",
        "sqlite-monitor",
        &[
            "FROM ZCACHEDWORKITEM",
            "ORDER BY ZUPDATEDAT DESC",
            "LIMIT 20",
        ],
    );
    assert_sqlite_table_panel(
        &dashboard,
        "Cached Agent Activity",
        "sqlite-monitor",
        &[
            "FROM ZCACHEDAGENTACTIVITY",
            "GROUP BY ZRUNTIME",
            "ORDER BY tool_calls DESC",
        ],
    );
}

#[test]
fn sqlite_forensics_dashboard_falls_back_when_monitor_record_count_metric_is_missing() {
    let dashboard = load_dashboard("sqlite-forensics.json");
    let exprs = panel_exprs(&dashboard, "Monitor Table and Record Counts");
    let record_counts_expr = exprs
        .get(1)
        .unwrap_or_else(|| panic!("missing monitor record count query"));

    assert!(
        record_counts_expr.contains("harness_monitor_sqlite_record_count"),
        "record count query should still prefer the monitor-emitted metric, got: {record_counts_expr}"
    );
    assert!(
        record_counts_expr.contains("label_replace(")
            && record_counts_expr.contains("harness_sqlite_table_rows{database=\"monitor_cache\"}")
            && record_counts_expr.contains("\"db_entity\"")
            && record_counts_expr.contains("\"entity\""),
        "record count query should fall back to the exporter table rows when the monitor gauge is absent, got: {record_counts_expr}"
    );
}
