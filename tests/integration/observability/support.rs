use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug)]
pub(super) struct DashboardLink {
    pub(super) title: String,
    pub(super) url: String,
}

pub(super) fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

pub(super) fn load_dashboard(name: &str) -> Value {
    let path = repo_root()
        .join("resources/observability/grafana/dashboards")
        .join(name);
    let content = fs::read_to_string(&path).unwrap();
    serde_json::from_str(&content).unwrap()
}

pub(super) fn load_yaml_file<T>(relative_path: &str) -> T
where
    T: for<'de> Deserialize<'de>,
{
    let path = repo_root().join(relative_path);
    let content = fs::read_to_string(&path).unwrap();
    serde_yml::from_str(&content).unwrap()
}

pub(super) fn dashboard_json_paths(root: &Path) -> Vec<PathBuf> {
    let mut paths = fs::read_dir(root)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("json"))
        .collect::<Vec<_>>();
    paths.sort();
    paths
}

pub(super) fn panel_expr(dashboard: &Value, title: &str) -> String {
    panel_exprs(dashboard, title)
        .into_iter()
        .next()
        .unwrap_or_else(|| panic!("missing panel expression for {title}"))
}

pub(super) fn panel_exprs(dashboard: &Value, title: &str) -> Vec<String> {
    panel_by_title(dashboard, title)["targets"]
        .as_array()
        .unwrap_or_else(|| panic!("missing panel targets for {title}"))
        .iter()
        .map(|target| {
            target["expr"]
                .as_str()
                .unwrap_or_else(|| panic!("missing panel expression for {title}"))
                .to_string()
        })
        .collect()
}

pub(super) fn assert_sqlite_table_panel(
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

pub(super) fn panel_by_title<'a>(dashboard: &'a Value, title: &str) -> &'a Value {
    dashboard["panels"]
        .as_array()
        .unwrap()
        .iter()
        .find(|panel| panel["title"].as_str() == Some(title))
        .unwrap_or_else(|| panic!("missing panel {title}"))
}

pub(super) fn collect_trace_links(value: &Value) -> Vec<DashboardLink> {
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
pub(super) struct ComposeFile {
    pub(super) services: BTreeMap<String, ComposeService>,
}

#[derive(Debug, Deserialize)]
pub(super) struct ComposeService {
    #[serde(default)]
    pub(super) command: Option<Vec<String>>,
    #[serde(default)]
    pub(super) environment: Option<BTreeMap<String, String>>,
    #[serde(default)]
    pub(super) healthcheck: Option<ComposeHealthcheck>,
    #[serde(default)]
    pub(super) user: Option<String>,
    #[serde(default)]
    pub(super) volumes: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
pub(super) struct ComposeHealthcheck {
    #[serde(default)]
    pub(super) test: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
pub(super) struct DatasourceProvisioning {
    pub(super) datasources: Vec<ProvisionedDatasource>,
}

#[derive(Debug, Deserialize)]
pub(super) struct QueryExporterConfig {
    pub(super) databases: BTreeMap<String, QueryExporterDatabase>,
}

#[derive(Debug, Deserialize)]
pub(super) struct QueryExporterDatabase {
    pub(super) dsn: String,
}

#[derive(Debug, Deserialize)]
pub(super) struct ProvisionedDatasource {
    pub(super) uid: String,
    #[serde(rename = "type")]
    pub(super) kind: String,
    #[serde(rename = "jsonData", default)]
    pub(super) json_data: SqliteDatasourceJsonData,
}

#[derive(Debug, Default, Deserialize)]
pub(super) struct SqliteDatasourceJsonData {
    #[serde(default)]
    pub(super) path: Option<String>,
    #[serde(rename = "pathOptions", default)]
    pub(super) path_options: Option<String>,
}
