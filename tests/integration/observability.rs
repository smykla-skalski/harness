use std::fs;
use std::path::{Path, PathBuf};

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

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
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
