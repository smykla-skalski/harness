use std::fs;
use std::path::PathBuf;
use std::process::Command;

use rusqlite::Connection;
use tempfile::tempdir;

use super::support::{
    seed_sqlite_database, write_fake_observability_harness_binary, write_fake_shell_tool,
};

#[test]
fn observability_script_runs_smoke_cli_via_local_binary_without_otel_env() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_binary = tmp.path().join("fake-bin/harness");
    let log_path = tmp.path().join("fake-harness.log");
    write_fake_observability_harness_binary(&fake_binary);

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--run-local-harness-fixture")
        .arg("session")
        .arg("list")
        .arg("--json")
        .current_dir(&repo)
        .env("HOME", tmp.path().join("home"))
        .env("FAKE_HARNESS_LOG", &log_path)
        .env("HARNESS_OBSERVABILITY_HARNESS_BIN", &fake_binary)
        .env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://example.com:4317")
        .env("OTEL_EXPORTER_OTLP_HEADERS", "authorization=Bearer test")
        .env("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf")
        .env("HARNESS_OTEL_EXPORT", "1")
        .env("HARNESS_OTEL_GRAFANA_URL", "http://grafana.invalid")
        .env("HARNESS_OTEL_PYROSCOPE_URL", "http://pyroscope.invalid")
        .output()
        .expect("run local harness observability fixture");

    assert!(
        output.status.success(),
        "fixture failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let log = std::fs::read_to_string(&log_path).expect("read fake harness log");
    assert!(
        log.contains("ARGS=session list --json"),
        "expected fixture to invoke the fake harness binary, got: {log}"
    );
    for key in [
        "OTEL_EXPORTER_OTLP_ENDPOINT=[]",
        "OTEL_EXPORTER_OTLP_HEADERS=[]",
        "OTEL_EXPORTER_OTLP_PROTOCOL=[]",
        "HARNESS_OTEL_EXPORT=[]",
        "HARNESS_OTEL_GRAFANA_URL=[]",
        "HARNESS_OTEL_PYROSCOPE_URL=[]",
    ] {
        assert!(log.contains(key), "expected cleared env {key}, got: {log}");
    }
}

#[test]
fn observability_script_smoke_restore_recreates_sqlite_snapshot_grafana_and_sqlite_exporter() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_bin = tmp.path().join("fake-bin");
    let log_path = tmp.path().join("observability-tools.log");

    write_fake_shell_tool(
        &fake_bin.join("docker"),
        "#!/bin/sh\nset -eu\nprintf 'DOCKER=%s\\n' \"$*\" >>\"$FAKE_OBSERVABILITY_LOG\"\n",
    );
    write_fake_shell_tool(
        &fake_bin.join("curl"),
        "#!/bin/sh\nset -eu\nprintf 'CURL=%s\\n' \"$*\" >>\"$FAKE_OBSERVABILITY_LOG\"\n",
    );

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--restore-smoke-stack-fixture")
        .current_dir(&repo)
        .env("HOME", tmp.path().join("home"))
        .env("FAKE_OBSERVABILITY_LOG", &log_path)
        .env("PATH", format!("{}:/usr/bin:/bin", fake_bin.display()))
        .output()
        .expect("run observability smoke restore fixture");

    assert!(
        output.status.success(),
        "fixture failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let log = std::fs::read_to_string(&log_path).expect("read fake observability log");
    assert!(
        log.contains(
            &format!(
                "DOCKER=compose -p harness-observability -f {} up -d --build --force-recreate sqlite-snapshot sqlite-exporter grafana",
                repo.join("resources/observability/docker-compose.yml").display()
            )
        ),
        "expected smoke restore to recreate sqlite-snapshot, Grafana, and sqlite-exporter, got: {log}"
    );
    assert!(
        log.contains("CURL=-fsS http://127.0.0.1:9560/metrics"),
        "expected smoke restore to wait for sqlite-exporter readiness, got: {log}"
    );
    assert!(
        log.contains("CURL=-fsS http://127.0.0.1:3000/api/health"),
        "expected smoke restore to wait for Grafana readiness, got: {log}"
    );
}

#[test]
fn observability_script_waits_longer_for_service_graph_edges_than_generic_signals() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_bin = tmp.path().join("fake-bin");
    let counter_path = tmp.path().join("curl-attempts.txt");

    write_fake_shell_tool(
        &fake_bin.join("curl"),
        "#!/bin/sh\nset -eu\ncount_file=\"$FAKE_CURL_COUNT_FILE\"\ncount=0\nif [ -f \"$count_file\" ]; then\n  count=$(cat \"$count_file\")\nfi\ncount=$((count + 1))\nprintf '%s' \"$count\" >\"$count_file\"\nif [ \"$count\" -lt 4 ]; then\n  printf '%s' '{\"status\":\"success\",\"data\":{\"result\":[]}}'\n  exit 0\nfi\nprintf '%s' '{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"client\":\"harness-monitor\",\"server\":\"harness-daemon\"},\"value\":[0,\"1\"]}]}}'\n",
    );

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--wait-for-service-graph-edge-fixture")
        .arg("harness-monitor")
        .arg("harness-daemon")
        .current_dir(&repo)
        .env("BASH_ENV", "/dev/null")
        .env("HOME", tmp.path().join("home"))
        .env("FAKE_CURL_COUNT_FILE", &counter_path)
        .env("HARNESS_OBSERVABILITY_SIGNAL_MAX_ATTEMPTS", "2")
        .env("HARNESS_OBSERVABILITY_SERVICE_GRAPH_MAX_ATTEMPTS", "4")
        .env("MISE_TRUSTED_CONFIG_PATHS", &repo)
        .env("PATH", format!("{}:/usr/bin:/bin", fake_bin.display()))
        .output()
        .expect("run service graph wait fixture");

    assert!(
        output.status.success(),
        "fixture failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let attempts = std::fs::read_to_string(&counter_path).expect("read curl attempt count");
    assert_eq!(attempts, "4");
}

#[test]
fn sqlite_snapshot_sync_copies_live_databases_into_stable_read_targets() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_daemon = tmp.path().join("source/daemon/harness.db");
    let source_monitor = tmp.path().join("source/monitor/harness-cache.store");
    let snapshot_daemon = tmp.path().join("snapshots/daemon/harness.db");
    let snapshot_monitor = tmp.path().join("snapshots/monitor/harness-cache.store");

    seed_sqlite_database(
        &source_daemon,
        "CREATE TABLE sessions (title TEXT NOT NULL);",
        "INSERT INTO sessions(title) VALUES ('daemon snapshot');",
    );
    seed_sqlite_database(
        &source_monitor,
        "CREATE TABLE ZCACHEDSESSION (ZTITLE TEXT NOT NULL);",
        "INSERT INTO ZCACHEDSESSION(ZTITLE) VALUES ('monitor snapshot');",
    );

    let output = Command::new("python3")
        .arg(repo.join("resources/observability/sqlite-snapshot/sync.py"))
        .arg("--once")
        .current_dir(&repo)
        .env("HARNESS_SQLITE_SOURCE_DAEMON_DB_PATH", &source_daemon)
        .env("HARNESS_SQLITE_SOURCE_MONITOR_DB_PATH", &source_monitor)
        .env("HARNESS_SQLITE_SNAPSHOT_DAEMON_DB_PATH", &snapshot_daemon)
        .env("HARNESS_SQLITE_SNAPSHOT_MONITOR_DB_PATH", &snapshot_monitor)
        .output()
        .expect("run sqlite snapshot sync");

    assert!(
        output.status.success(),
        "sqlite snapshot sync failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let daemon_connection = Connection::open(&snapshot_daemon).expect("open daemon snapshot");
    let daemon_journal_mode: String = daemon_connection
        .query_row("PRAGMA journal_mode", [], |row| row.get(0))
        .expect("read daemon snapshot journal mode");
    let daemon_title: String = daemon_connection
        .query_row("SELECT title FROM sessions", [], |row| row.get(0))
        .expect("read daemon snapshot row");
    assert_eq!(daemon_journal_mode, "delete");
    assert_eq!(daemon_title, "daemon snapshot");

    let monitor_connection = Connection::open(&snapshot_monitor).expect("open monitor snapshot");
    let monitor_journal_mode: String = monitor_connection
        .query_row("PRAGMA journal_mode", [], |row| row.get(0))
        .expect("read monitor snapshot journal mode");
    let monitor_title: String = monitor_connection
        .query_row("SELECT ZTITLE FROM ZCACHEDSESSION", [], |row| row.get(0))
        .expect("read monitor snapshot row");
    assert_eq!(monitor_journal_mode, "delete");
    assert_eq!(monitor_title, "monitor snapshot");
}

#[test]
fn grafana_star_initializer_uses_v2_uid_star_endpoint() {
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let script =
        fs::read_to_string(repo.join("resources/observability/grafana/init-star-dashboards.sh"))
            .expect("read init-star-dashboards.sh");

    assert!(
        script.contains("/api/user/stars/dashboard/uid/$uid"),
        "expected Grafana star initializer to use the UID star endpoint for v2 dashboards, got: {script}"
    );
    assert!(
        !script.contains("/api/user/stars/dashboard/$id"),
        "star initializer should not rely on legacy numeric dashboard ids for v2 dashboards"
    );
}

#[test]
fn observability_v2_dashboard_verifier_uses_uid_not_legacy_provisioned_flag() {
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let script =
        fs::read_to_string(repo.join("scripts/observability.sh")).expect("read observability.sh");

    assert!(
        script.contains(".dashboard.uid == $uid"),
        "expected v2 dashboard verification to match the stable dashboard uid, got: {script}"
    );
    assert!(
        !script.contains(".meta.provisioned == true"),
        "v2 dashboard verification should not rely on the legacy provisioned flag"
    );
}

#[test]
fn observability_status_prefers_rtk_wrapped_compose_output_when_available() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_bin = tmp.path().join("fake-bin");
    let log_path = tmp.path().join("fake-compose.log");

    write_fake_shell_tool(
        &fake_bin.join("rtk"),
        "#!/bin/sh\nset -eu\nprintf 'RTK=%s\\n' \"$*\" >\"$FAKE_OBSERVABILITY_LOG\"\n",
    );
    write_fake_shell_tool(
        &fake_bin.join("docker"),
        "#!/bin/sh\nset -eu\nprintf 'DOCKER=%s\\n' \"$*\" >\"$FAKE_OBSERVABILITY_LOG\"\n",
    );

    let output = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("status")
        .current_dir(&repo)
        .env("FAKE_OBSERVABILITY_LOG", &log_path)
        .env("HOME", tmp.path().join("home"))
        .env("PATH", format!("{}:/usr/bin:/bin", fake_bin.display()))
        .output()
        .expect("run observability status");

    assert!(
        output.status.success(),
        "script failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let log = std::fs::read_to_string(&log_path).expect("read fake observability log");
    assert!(
        log.contains(&format!(
            "RTK=docker compose -p harness-observability -f {} ps",
            repo.join("resources/observability/docker-compose.yml")
                .display()
        )),
        "expected observability status to prefer RTK-wrapped docker compose ps, got: {log}"
    );
    assert!(
        !log.contains("DOCKER="),
        "expected observability status to avoid raw docker compose output when RTK is available: {log}"
    );
}
