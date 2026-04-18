use super::support::{
    ComposeFile, DatasourceProvisioning, QueryExporterConfig, load_yaml_file, repo_root,
};

#[test]
fn grafana_compose_routes_sqlite_reads_through_snapshot_copies() {
    let compose: ComposeFile = load_yaml_file("resources/observability/docker-compose.yml");
    let sqlite_snapshot = compose
        .services
        .get("sqlite-snapshot")
        .expect("sqlite-snapshot service should exist");
    let sqlite_snapshot_volumes = sqlite_snapshot
        .volumes
        .as_ref()
        .expect("sqlite-snapshot should declare volumes");
    let sqlite_snapshot_command = sqlite_snapshot
        .command
        .as_ref()
        .expect("sqlite-snapshot should declare a command");
    let exporter = compose
        .services
        .get("sqlite-exporter")
        .expect("sqlite-exporter service should exist");
    let exporter_volumes = exporter
        .volumes
        .as_ref()
        .expect("sqlite-exporter should declare volumes");
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
        sqlite_snapshot_command,
        &vec![
            "python3".to_string(),
            "/app/sync.py".to_string(),
            "--interval".to_string(),
            "2".to_string(),
        ],
        "sqlite-snapshot should run the dedicated snapshot sync loop"
    );
    assert!(
        sqlite_snapshot_volumes.contains(&"./sqlite-snapshot/sync.py:/app/sync.py:ro".to_string()),
        "sqlite-snapshot should mount the snapshot sync script"
    );
    assert!(
        sqlite_snapshot_volumes
            .contains(&"${HARNESS_SQLITE_SOURCE_DAEMON_DIR}:/srv/source/daemon:ro".to_string()),
        "sqlite-snapshot should mount the live daemon database source read-only"
    );
    assert!(
        sqlite_snapshot_volumes
            .contains(&"${HARNESS_SQLITE_SOURCE_MONITOR_DIR}:/srv/source/monitor:ro".to_string()),
        "sqlite-snapshot should mount the live monitor database source read-only"
    );
    assert!(
        sqlite_snapshot_volumes
            .contains(&"${HARNESS_SQLITE_SNAPSHOT_DAEMON_DIR}:/srv/sqlite/daemon:rw".to_string()),
        "sqlite-snapshot should publish daemon snapshots into the shared snapshot directory"
    );
    assert!(
        sqlite_snapshot_volumes
            .contains(&"${HARNESS_SQLITE_SNAPSHOT_MONITOR_DIR}:/srv/sqlite/monitor:rw".to_string()),
        "sqlite-snapshot should publish monitor snapshots into the shared snapshot directory"
    );
    assert_eq!(
        grafana.user.as_deref(),
        Some("0"),
        "grafana should continue running as root inside the local stack"
    );
    assert!(
        exporter_volumes
            .contains(&"${HARNESS_SQLITE_SNAPSHOT_DAEMON_DIR}:/srv/sqlite/daemon:ro".to_string()),
        "sqlite-exporter should read the daemon snapshot copy"
    );
    assert!(
        exporter_volumes
            .contains(&"${HARNESS_SQLITE_SNAPSHOT_MONITOR_DIR}:/srv/sqlite/monitor:ro".to_string()),
        "sqlite-exporter should read the monitor snapshot copy"
    );
    assert!(
        volumes
            .contains(&"${HARNESS_SQLITE_SNAPSHOT_DAEMON_DIR}:/srv/sqlite/daemon:ro".to_string()),
        "grafana should mount the daemon snapshot directory read-only"
    );
    assert!(
        volumes
            .contains(&"${HARNESS_SQLITE_SNAPSHOT_MONITOR_DIR}:/srv/sqlite/monitor:ro".to_string()),
        "grafana should mount the monitor snapshot directory read-only"
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
fn distroless_observability_backends_use_external_readiness_checks() {
    let compose: ComposeFile = load_yaml_file("resources/observability/docker-compose.yml");

    for service_name in ["alloy", "loki", "tempo", "pyroscope"] {
        let service = compose
            .services
            .get(service_name)
            .unwrap_or_else(|| panic!("missing {service_name} service"));
        assert!(
            service.healthcheck.is_none(),
            "{service_name} should rely on host-side readiness checks instead of an in-container probe command that may not exist in the upstream image"
        );
    }
}

#[test]
fn sqlite_exporter_healthcheck_uses_curl_probe() {
    let compose: ComposeFile = load_yaml_file("resources/observability/docker-compose.yml");
    let service = compose
        .services
        .get("sqlite-exporter")
        .expect("missing sqlite-exporter service");
    let test = service
        .healthcheck
        .as_ref()
        .and_then(|healthcheck| healthcheck.test.as_ref())
        .expect("sqlite-exporter should declare a healthcheck command");

    assert!(
        test.iter().any(|part| part.contains("curl")),
        "sqlite-exporter should use curl for its in-container healthcheck, got: {test:?}"
    );
}

#[test]
fn sqlite_exporter_uses_read_only_sqlalchemy_uris_for_snapshot_copies() {
    let config: QueryExporterConfig =
        load_yaml_file("resources/observability/query-exporter/config.yml");
    let daemon_dsn = config
        .databases
        .get("daemon_db")
        .expect("missing daemon_db query-exporter config");
    let monitor_dsn = config
        .databases
        .get("monitor_cache")
        .expect("missing monitor_cache query-exporter config");

    for (name, dsn) in [
        ("daemon_db", &daemon_dsn.dsn),
        ("monitor_cache", &monitor_dsn.dsn),
    ] {
        assert!(
            dsn.contains("mode=ro"),
            "{name} should open the snapshot copy in read-only mode, got: {dsn}"
        );
        assert!(
            dsn.contains("uri=true"),
            "{name} should enable SQLAlchemy SQLite URI parsing, got: {dsn}"
        );
        assert!(
            dsn.contains("file:/srv/sqlite/"),
            "{name} should use a SQLite file URI so mode=ro is applied by the driver, got: {dsn}"
        );
    }
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
    assert!(
        daemon
            .json_data
            .path_options
            .as_deref()
            .is_some_and(|options| {
                options.contains("mode=ro") && options.contains("_busy_timeout=5000")
            }),
        "sqlite-daemon should use a read-only SQLite DSN with a busy timeout to ride out short-lived writer locks"
    );
    assert_eq!(monitor.kind, "frser-sqlite-datasource");
    assert_eq!(
        monitor.json_data.path.as_deref(),
        Some("/srv/sqlite/monitor/harness-cache.store")
    );
    assert!(
        monitor
            .json_data
            .path_options
            .as_deref()
            .is_some_and(|options| {
                options.contains("mode=ro") && options.contains("_busy_timeout=5000")
            }),
        "sqlite-monitor should use a read-only SQLite DSN with a busy timeout to ride out short-lived writer locks"
    );
}

#[test]
fn grafana_ini_does_not_hardcode_admin_credentials() {
    let path = repo_root().join("resources/observability/grafana/grafana.ini");
    let config = std::fs::read_to_string(&path).unwrap();

    assert!(
        !config.contains("admin_user ="),
        "grafana.ini should not hardcode the admin user once compose provides GF_SECURITY_ADMIN_USER"
    );
    assert!(
        !config.contains("admin_password ="),
        "grafana.ini should not hardcode the admin password once compose provides GF_SECURITY_ADMIN_PASSWORD"
    );
}

#[test]
fn grafana_default_home_dashboard_points_to_a_provisioned_dashboard() {
    let config_path = repo_root().join("resources/observability/grafana/grafana.ini");
    let config = std::fs::read_to_string(&config_path).unwrap();
    let configured_dashboard = config
        .lines()
        .find_map(|line| {
            let trimmed = line.trim();
            trimmed
                .strip_prefix("default_home_dashboard_path =")
                .map(str::trim)
        })
        .unwrap_or_else(|| {
            panic!(
                "grafana.ini should configure a default home dashboard path in {}",
                config_path.display()
            )
        });
    let dashboard_name = std::path::Path::new(configured_dashboard)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_else(|| panic!("invalid Grafana home dashboard path: {configured_dashboard}"));
    let dashboard_path = repo_root()
        .join("resources/observability/grafana/dashboards")
        .join(dashboard_name);

    assert!(
        dashboard_path.is_file(),
        "grafana home dashboard should point to a provisioned dashboard JSON, got {configured_dashboard}"
    );
    assert_eq!(
        dashboard_name, "service-map.json",
        "Grafana home dashboard should use the documented Harness Service Flow landing page"
    );
}
