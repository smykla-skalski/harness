use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug)]
struct DashboardLink {
    title: String,
    url: String,
}

#[test]
fn traces_dashboard_links_use_supported_local_views() {
    let dashboards_root = repo_root().join("resources/observability/grafana/dashboards");
    let dashboard_paths = dashboard_json_paths(&dashboards_root);

    assert!(
        !dashboard_paths.is_empty(),
        "expected dashboard JSON files under {}",
        dashboards_root.display()
    );

    let mut checked_links = 0;
    for path in dashboard_paths {
        let content = fs::read_to_string(&path).unwrap();
        let dashboard: Value = serde_json::from_str(&content).unwrap();

        for link in collect_trace_links(&dashboard) {
            checked_links += 1;
            assert!(
                !link.url.contains("actionView=structure"),
                "{} should not send local Grafana users into the broken Structure tab: {}",
                path.display(),
                link.url
            );
            assert!(
                link.url.contains("actionView=breakdown")
                    || link.url.contains("actionView=traceList"),
                "{} should use a supported local traces landing view: {}",
                path.display(),
                link.url
            );
            assert!(
                link.title.contains("Breakdown") || link.title.contains("Traces"),
                "{} should describe the supported traces landing view in link title {:?}",
                path.display(),
                link.title
            );
            assert!(
                !link.title.contains("Drilldown"),
                "{} should not present local traces links as generic drilldown entry points: {:?}",
                path.display(),
                link.title
            );
        }
    }

    assert!(
        checked_links > 0,
        "expected at least one traces dashboard link"
    );
}

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
fn grafana_compose_installs_sqlite_plugin_and_mounts_live_databases() {
    let compose: ComposeFile = load_yaml_file("resources/observability/docker-compose.yml");
    let grafana = compose
        .services
        .get("grafana")
        .expect("grafana service should exist");
    let plugin_list = grafana
        .environment
        .as_ref()
        .and_then(|env| env.get("GF_PLUGINS_PREINSTALL_SYNC"))
        .expect("grafana should declare preinstalled plugins");
    let volumes = grafana
        .volumes
        .as_ref()
        .expect("grafana should declare volumes");

    assert!(
        plugin_list.contains("frser-sqlite-datasource"),
        "grafana should install the sqlite datasource plugin, got: {plugin_list}"
    );
    assert_eq!(
        grafana.user.as_deref(),
        Some("0"),
        "grafana should run as root so the sqlite plugin can query live WAL databases"
    );
    assert!(
        volumes
            .contains(&"${HARNESS_SQLITE_EXPORTER_DAEMON_DIR}:/srv/sqlite/daemon:rw".to_string()),
        "grafana should mount the daemon sqlite directory read-write"
    );
    assert!(
        volumes
            .contains(&"${HARNESS_SQLITE_EXPORTER_MONITOR_DIR}:/srv/sqlite/monitor:rw".to_string()),
        "grafana should mount the monitor sqlite directory read-write"
    );
    let environment = grafana
        .environment
        .as_ref()
        .expect("grafana should declare environment");
    assert_eq!(
        environment
            .get("GF_SECURITY_ADMIN_USER")
            .map(String::as_str),
        Some("${GF_SECURITY_ADMIN_USER:-admin}"),
        "grafana should source the admin user from the observability env file"
    );
    assert_eq!(
        environment
            .get("GF_SECURITY_ADMIN_PASSWORD")
            .map(String::as_str),
        Some("${GF_SECURITY_ADMIN_PASSWORD:-harness}"),
        "grafana should source the admin password from the observability env file"
    );
}

#[test]
fn grafana_provisions_sqlite_datasources_for_daemon_and_monitor_databases() {
    let provisioning: DatasourceProvisioning =
        load_yaml_file("resources/observability/grafana/provisioning/datasources/datasources.yml");
    let daemon = provisioning
        .datasources
        .iter()
        .find(|datasource| datasource.uid == "sqlite-daemon")
        .expect("missing sqlite-daemon datasource");
    let monitor = provisioning
        .datasources
        .iter()
        .find(|datasource| datasource.uid == "sqlite-monitor")
        .expect("missing sqlite-monitor datasource");

    assert_eq!(daemon.kind, "frser-sqlite-datasource");
    assert_eq!(
        daemon.json_data.path.as_deref(),
        Some("/srv/sqlite/daemon/harness.db")
    );
    assert_eq!(monitor.kind, "frser-sqlite-datasource");
    assert_eq!(
        monitor.json_data.path.as_deref(),
        Some("/srv/sqlite/monitor/harness-cache.store")
    );
}

#[test]
fn grafana_ini_does_not_hardcode_admin_credentials() {
    let path = repo_root().join("resources/observability/grafana/grafana.ini");
    let config = fs::read_to_string(&path).unwrap();

    assert!(
        !config.contains("admin_user ="),
        "grafana.ini should not hardcode the admin user once compose provides GF_SECURITY_ADMIN_USER"
    );
    assert!(
        !config.contains("admin_password ="),
        "grafana.ini should not hardcode the admin password once compose provides GF_SECURITY_ADMIN_PASSWORD"
    );
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn load_dashboard(name: &str) -> Value {
    let path = repo_root()
        .join("resources/observability/grafana/dashboards")
        .join(name);
    let content = fs::read_to_string(&path).unwrap();
    serde_json::from_str(&content).unwrap()
}

fn load_yaml_file<T>(relative_path: &str) -> T
where
    T: for<'de> Deserialize<'de>,
{
    let path = repo_root().join(relative_path);
    let content = fs::read_to_string(&path).unwrap();
    serde_yml::from_str(&content).unwrap()
}

fn dashboard_json_paths(root: &Path) -> Vec<PathBuf> {
    let mut paths = fs::read_dir(root)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("json"))
        .collect::<Vec<_>>();
    paths.sort();
    paths
}

fn panel_expr(dashboard: &Value, title: &str) -> String {
    panel_by_title(dashboard, title)["targets"]
        .as_array()
        .and_then(|targets| targets.first())
        .and_then(|target| target["expr"].as_str())
        .unwrap_or_else(|| panic!("missing panel expression for {title}"))
        .to_string()
}

fn assert_sqlite_table_panel(
    dashboard: &Value,
    title: &str,
    datasource_uid: &str,
    expected_fragments: &[&str],
) {
    let panel = panel_by_title(dashboard, title);
    assert_eq!(panel["type"].as_str(), Some("table"));
    assert_eq!(panel["datasource"]["uid"].as_str(), Some(datasource_uid));

    let target = panel["targets"]
        .as_array()
        .and_then(|targets| targets.first())
        .unwrap_or_else(|| panic!("missing target for {title}"));

    assert_eq!(target["queryType"].as_str(), Some("table"));
    assert_eq!(target["timeColumns"].as_array(), Some(&Vec::new()));

    let raw_query = target["rawQueryText"]
        .as_str()
        .unwrap_or_else(|| panic!("missing sqlite query text for {title}"));
    let query_text = target["queryText"]
        .as_str()
        .unwrap_or_else(|| panic!("missing sqlite rendered query text for {title}"));
    assert_eq!(raw_query, query_text);

    for fragment in expected_fragments {
        assert!(
            raw_query.contains(fragment),
            "{title} query should contain {fragment:?}, got: {raw_query}"
        );
    }
}

fn panel_by_title<'a>(dashboard: &'a Value, title: &str) -> &'a Value {
    dashboard["panels"]
        .as_array()
        .unwrap()
        .iter()
        .find(|panel| panel["title"].as_str() == Some(title))
        .unwrap_or_else(|| panic!("missing panel {title}"))
}

fn collect_trace_links(value: &Value) -> Vec<DashboardLink> {
    let mut links = Vec::new();
    collect_trace_links_inner(value, &mut links);
    links
}

fn collect_trace_links_inner(value: &Value, links: &mut Vec<DashboardLink>) {
    match value {
        Value::Object(map) => {
            if let (Some(Value::String(title)), Some(Value::String(url))) =
                (map.get("title"), map.get("url"))
            {
                if url.contains("/a/grafana-exploretraces-app/explore") {
                    links.push(DashboardLink {
                        title: title.clone(),
                        url: url.clone(),
                    });
                }
            }

            for child in map.values() {
                collect_trace_links_inner(child, links);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_trace_links_inner(item, links);
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {}
    }
}

#[derive(Debug, Deserialize)]
struct ComposeFile {
    services: BTreeMap<String, ComposeService>,
}

#[derive(Debug, Deserialize)]
struct ComposeService {
    #[serde(default)]
    environment: Option<BTreeMap<String, String>>,
    #[serde(default)]
    user: Option<String>,
    #[serde(default)]
    volumes: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
struct DatasourceProvisioning {
    datasources: Vec<ProvisionedDatasource>,
}

#[derive(Debug, Deserialize)]
struct ProvisionedDatasource {
    uid: String,
    #[serde(rename = "type")]
    kind: String,
    #[serde(rename = "jsonData", default)]
    json_data: SqliteDatasourceJsonData,
}

#[derive(Debug, Default, Deserialize)]
struct SqliteDatasourceJsonData {
    #[serde(default)]
    path: Option<String>,
}
