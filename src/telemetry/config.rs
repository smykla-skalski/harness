use std::collections::BTreeMap;
use std::env;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::infra::io::read_json_typed;
use crate::workspace::harness_data_root;
use crate::workspace::normalized_env_value;

pub const DEFAULT_OTLP_GRPC_ENDPOINT: &str = "http://127.0.0.1:4317";
pub const DEFAULT_OTLP_HTTP_ENDPOINT: &str = "http://127.0.0.1:4318";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportProtocol {
    Grpc,
    HttpProtobuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TelemetryConfigSource {
    Environment,
    SharedFile,
    Toggle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeService {
    Cli,
    Hook,
    Daemon,
    Bridge,
}

impl RuntimeService {
    #[must_use]
    pub const fn service_name(self) -> &'static str {
        match self {
            Self::Cli => "harness-cli",
            Self::Hook => "harness-hook",
            Self::Daemon => "harness-daemon",
            Self::Bridge => "harness-bridge",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SharedObservabilityConfig {
    pub enabled: bool,
    pub grpc_endpoint: String,
    pub http_endpoint: String,
    #[serde(default)]
    pub grafana_url: Option<String>,
    #[serde(default)]
    pub tempo_url: Option<String>,
    #[serde(default)]
    pub loki_url: Option<String>,
    #[serde(default)]
    pub prometheus_url: Option<String>,
    #[serde(default)]
    pub pyroscope_url: Option<String>,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedTelemetryConfig {
    pub source: TelemetryConfigSource,
    pub protocol: ExportProtocol,
    pub endpoint: String,
    pub grafana_url: Option<String>,
    pub pyroscope_url: Option<String>,
    pub headers: BTreeMap<String, String>,
}

#[must_use]
pub fn shared_config_path() -> PathBuf {
    harness_data_root()
        .join("observability")
        .join("config.json")
}

#[must_use]
pub fn runtime_service_from_args<S: AsRef<str>>(args: &[S]) -> RuntimeService {
    match args.get(1).map(AsRef::as_ref) {
        Some("hook") => RuntimeService::Hook,
        Some("daemon") => RuntimeService::Daemon,
        Some("bridge") => RuntimeService::Bridge,
        _ => RuntimeService::Cli,
    }
}

#[must_use]
pub fn runtime_service_from_current_process() -> RuntimeService {
    runtime_service_from_args(&env::args().collect::<Vec<_>>())
}

/// # Errors
///
/// Returns an error when the shared observability configuration exists but cannot
/// be read or deserialized.
pub fn resolve_telemetry_config() -> Result<Option<ResolvedTelemetryConfig>, CliError> {
    if let Some(config) = resolve_from_explicit_env() {
        return Ok(Some(config));
    }

    if let Some(config) = resolve_from_shared_file()? {
        return Ok(Some(config));
    }

    if env_truthy("HARNESS_OTEL_EXPORT") {
        return Ok(Some(ResolvedTelemetryConfig {
            source: TelemetryConfigSource::Toggle,
            protocol: ExportProtocol::Grpc,
            endpoint: DEFAULT_OTLP_GRPC_ENDPOINT.to_string(),
            grafana_url: None,
            pyroscope_url: None,
            headers: BTreeMap::new(),
        }));
    }

    Ok(None)
}

fn resolve_from_explicit_env() -> Option<ResolvedTelemetryConfig> {
    let endpoint = normalized_env_value("OTEL_EXPORTER_OTLP_ENDPOINT")?;
    let protocol = resolve_protocol_from_env();
    let headers = normalized_env_value("OTEL_EXPORTER_OTLP_HEADERS")
        .map_or_else(BTreeMap::new, |raw| parse_otel_headers(&raw));

    Some(ResolvedTelemetryConfig {
        source: TelemetryConfigSource::Environment,
        protocol,
        endpoint,
        grafana_url: normalized_env_value("HARNESS_OTEL_GRAFANA_URL"),
        pyroscope_url: normalized_env_value("HARNESS_OTEL_PYROSCOPE_URL"),
        headers,
    })
}

fn resolve_from_shared_file() -> Result<Option<ResolvedTelemetryConfig>, CliError> {
    let path = shared_config_path();
    if !path.is_file() {
        return Ok(None);
    }

    let shared: SharedObservabilityConfig = read_json_typed(&path)?;
    if !shared.enabled {
        return Ok(None);
    }

    let protocol = resolve_protocol_from_env();
    let endpoint = match protocol {
        ExportProtocol::Grpc => shared.grpc_endpoint,
        ExportProtocol::HttpProtobuf => shared.http_endpoint,
    };

    Ok(Some(ResolvedTelemetryConfig {
        source: TelemetryConfigSource::SharedFile,
        protocol,
        endpoint,
        grafana_url: shared.grafana_url,
        pyroscope_url: shared.pyroscope_url,
        headers: shared.headers,
    }))
}

fn resolve_protocol_from_env() -> ExportProtocol {
    match normalized_env_value("OTEL_EXPORTER_OTLP_PROTOCOL").as_deref() {
        Some("http/protobuf") => ExportProtocol::HttpProtobuf,
        _ => ExportProtocol::Grpc,
    }
}

fn parse_otel_headers(raw: &str) -> BTreeMap<String, String> {
    raw.split(',')
        .filter_map(|entry| {
            let (key, value) = entry.split_once('=')?;
            let key = key.trim();
            let value = value.trim();
            if key.is_empty() || value.is_empty() {
                return None;
            }
            Some((key.to_string(), value.to_string()))
        })
        .collect()
}

fn env_truthy(name: &str) -> bool {
    matches!(
        normalized_env_value(name)
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str(),
        "1" | "true" | "yes" | "on"
    )
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::infra::io::write_json_pretty;

    #[test]
    fn shared_config_path_uses_harness_data_root() {
        let tmp = tempfile::tempdir().unwrap();
        let xdg_data = tmp.path().join("xdg-data");
        temp_env::with_var("XDG_DATA_HOME", Some(&xdg_data), || {
            assert_eq!(
                shared_config_path(),
                xdg_data
                    .join("harness")
                    .join("observability")
                    .join("config.json")
            );
        });
    }

    #[test]
    fn runtime_service_uses_hook_prefix() {
        assert_eq!(
            runtime_service_from_args(&["harness", "hook", "tool-guard"]),
            RuntimeService::Hook
        );
        assert_eq!(
            runtime_service_from_args(&["harness", "daemon", "serve"]),
            RuntimeService::Daemon
        );
        assert_eq!(
            runtime_service_from_args(&["harness", "bridge", "start"]),
            RuntimeService::Bridge
        );
        assert_eq!(
            runtime_service_from_args(&["harness", "session", "list"]),
            RuntimeService::Cli
        );
    }

    #[test]
    fn resolve_telemetry_config_loads_shared_file_when_env_is_absent() {
        let tmp = tempfile::tempdir().unwrap();
        let xdg_data = tmp.path().join("xdg-data");
        let xdg_data_str = xdg_data.to_str().unwrap();
        let config = SharedObservabilityConfig {
            enabled: true,
            grpc_endpoint: "http://127.0.0.1:4317".to_string(),
            http_endpoint: "http://127.0.0.1:4318".to_string(),
            grafana_url: Some("http://127.0.0.1:3000".to_string()),
            tempo_url: None,
            loki_url: None,
            prometheus_url: None,
            pyroscope_url: Some("http://127.0.0.1:4040".to_string()),
            headers: BTreeMap::from([("x-harness-env".to_string(), "local".to_string())]),
        };

        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(xdg_data_str)),
                ("OTEL_EXPORTER_OTLP_ENDPOINT", None),
                ("OTEL_EXPORTER_OTLP_PROTOCOL", None),
                ("OTEL_EXPORTER_OTLP_HEADERS", None),
                ("HARNESS_OTEL_EXPORT", None),
            ],
            || {
                write_json_pretty(&shared_config_path(), &config).unwrap();

                let resolved = resolve_telemetry_config()
                    .unwrap()
                    .expect("shared file should enable telemetry");

                assert_eq!(resolved.source, TelemetryConfigSource::SharedFile);
                assert_eq!(resolved.protocol, ExportProtocol::Grpc);
                assert_eq!(resolved.endpoint, config.grpc_endpoint);
                assert_eq!(resolved.grafana_url, config.grafana_url);
                assert_eq!(resolved.pyroscope_url, config.pyroscope_url);
                assert_eq!(resolved.headers, config.headers);
            },
        );
    }

    #[test]
    fn resolve_telemetry_config_prefers_environment_over_shared_file() {
        let tmp = tempfile::tempdir().unwrap();
        let xdg_data = tmp.path().join("xdg-data");
        let xdg_data_str = xdg_data.to_str().unwrap();
        let config = SharedObservabilityConfig {
            enabled: true,
            grpc_endpoint: "http://127.0.0.1:4317".to_string(),
            http_endpoint: "http://127.0.0.1:4318".to_string(),
            grafana_url: Some("http://127.0.0.1:3000".to_string()),
            tempo_url: None,
            loki_url: None,
            prometheus_url: None,
            pyroscope_url: Some("http://127.0.0.1:4040".to_string()),
            headers: BTreeMap::from([("x-harness-env".to_string(), "file".to_string())]),
        };

        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(xdg_data_str)),
                (
                    "OTEL_EXPORTER_OTLP_ENDPOINT",
                    Some("http://collector.example:55681"),
                ),
                ("OTEL_EXPORTER_OTLP_PROTOCOL", Some("http/protobuf")),
                (
                    "OTEL_EXPORTER_OTLP_HEADERS",
                    Some("authorization=Bearer abc123,x-harness-env=env"),
                ),
                ("HARNESS_OTEL_PYROSCOPE_URL", Some("http://127.0.0.1:4404")),
                ("HARNESS_OTEL_EXPORT", None),
            ],
            || {
                write_json_pretty(&shared_config_path(), &config).unwrap();

                let resolved = resolve_telemetry_config()
                    .unwrap()
                    .expect("env should enable telemetry");

                assert_eq!(resolved.source, TelemetryConfigSource::Environment);
                assert_eq!(resolved.protocol, ExportProtocol::HttpProtobuf);
                assert_eq!(resolved.endpoint, "http://collector.example:55681");
                assert_eq!(
                    resolved.pyroscope_url,
                    Some("http://127.0.0.1:4404".to_string())
                );
                assert_eq!(
                    resolved.headers,
                    BTreeMap::from([
                        ("authorization".to_string(), "Bearer abc123".to_string()),
                        ("x-harness-env".to_string(), "env".to_string()),
                    ])
                );
            },
        );
    }

    #[test]
    fn resolve_telemetry_config_uses_toggle_defaults_when_requested() {
        let tmp = tempfile::tempdir().unwrap();
        let xdg_data = tmp.path().join("xdg-data");
        let xdg_data_str = xdg_data.to_str().unwrap();

        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(xdg_data_str)),
                ("OTEL_EXPORTER_OTLP_ENDPOINT", None),
                ("OTEL_EXPORTER_OTLP_PROTOCOL", None),
                ("OTEL_EXPORTER_OTLP_HEADERS", None),
                ("HARNESS_OTEL_EXPORT", Some("1")),
            ],
            || {
                let resolved = resolve_telemetry_config()
                    .unwrap()
                    .expect("toggle should enable telemetry");

                assert_eq!(resolved.source, TelemetryConfigSource::Toggle);
                assert_eq!(resolved.protocol, ExportProtocol::Grpc);
                assert_eq!(resolved.endpoint, DEFAULT_OTLP_GRPC_ENDPOINT);
                assert_eq!(resolved.pyroscope_url, None);
                assert!(resolved.headers.is_empty());
            },
        );
    }
}
