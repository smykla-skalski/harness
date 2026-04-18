use std::collections::BTreeMap;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

use rusqlite::Connection;

pub(super) fn write_fake_harness_binary(path: &Path, version: &str) {
    std::fs::create_dir_all(path.parent().expect("binary parent")).expect("create binary dir");
    std::fs::write(
        path,
        format!(
            "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  echo 'harness {version}'\n  exit 0\nfi\nif [ \"$1\" = \"--help\" ]; then\n  echo 'Harness CLI'\n  exit 0\nfi\nexit 0\n"
        ),
    )
    .expect("write fake harness");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
        .expect("chmod fake harness");
}

pub(super) fn write_fake_observability_harness_binary(path: &Path) {
    std::fs::create_dir_all(path.parent().expect("binary parent")).expect("create binary dir");
    std::fs::write(
        path,
        "#!/bin/sh\nset -eu\nprintf 'ARGS=%s\\n' \"$*\" >\"$FAKE_HARNESS_LOG\"\nprintf 'OTEL_EXPORTER_OTLP_ENDPOINT=[%s]\\n' \"${OTEL_EXPORTER_OTLP_ENDPOINT-}\" >>\"$FAKE_HARNESS_LOG\"\nprintf 'OTEL_EXPORTER_OTLP_HEADERS=[%s]\\n' \"${OTEL_EXPORTER_OTLP_HEADERS-}\" >>\"$FAKE_HARNESS_LOG\"\nprintf 'OTEL_EXPORTER_OTLP_PROTOCOL=[%s]\\n' \"${OTEL_EXPORTER_OTLP_PROTOCOL-}\" >>\"$FAKE_HARNESS_LOG\"\nprintf 'HARNESS_OTEL_EXPORT=[%s]\\n' \"${HARNESS_OTEL_EXPORT-}\" >>\"$FAKE_HARNESS_LOG\"\nprintf 'HARNESS_OTEL_GRAFANA_URL=[%s]\\n' \"${HARNESS_OTEL_GRAFANA_URL-}\" >>\"$FAKE_HARNESS_LOG\"\nprintf 'HARNESS_OTEL_PYROSCOPE_URL=[%s]\\n' \"${HARNESS_OTEL_PYROSCOPE_URL-}\" >>\"$FAKE_HARNESS_LOG\"\n",
    )
    .expect("write fake observability harness");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
        .expect("chmod fake observability harness");
}

pub(super) fn write_fake_shell_tool(path: &Path, body: &str) {
    std::fs::create_dir_all(path.parent().expect("binary parent")).expect("create binary dir");
    std::fs::write(path, body).expect("write fake shell tool");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
        .expect("chmod fake shell tool");
}

pub(super) fn seed_sqlite_database(path: &Path, schema: &str, insert: &str) {
    std::fs::create_dir_all(path.parent().expect("db parent")).expect("create db dir");
    let connection = Connection::open(path).expect("open sqlite database");
    connection
        .pragma_update(None, "journal_mode", "WAL")
        .expect("enable WAL mode");
    connection.execute_batch(schema).expect("apply schema");
    connection.execute_batch(insert).expect("seed rows");
}

pub(super) fn run_harness_version(path: &Path) -> String {
    let output = Command::new(path)
        .arg("--version")
        .output()
        .expect("run harness --version");
    assert!(
        output.status.success(),
        "version command failed for {}: stdout={} stderr={}",
        path.display(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

pub(super) fn parse_env_output(output: &[u8]) -> BTreeMap<String, String> {
    String::from_utf8_lossy(output)
        .lines()
        .filter_map(|line| line.split_once('='))
        .map(|(key, value)| (key.to_string(), value.to_string()))
        .collect()
}

pub(super) fn parse_output_lines(output: &[u8]) -> Vec<String> {
    String::from_utf8_lossy(output)
        .lines()
        .map(ToString::to_string)
        .collect()
}
