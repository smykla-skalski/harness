use super::support::{collect_trace_links, dashboard_json_paths, repo_root};

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
        let content = std::fs::read_to_string(&path).unwrap();
        let dashboard: serde_json::Value = serde_json::from_str(&content).unwrap();

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
