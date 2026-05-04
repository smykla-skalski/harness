use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::time::Duration;

use pyroscope::PyroscopeError;
use pyroscope::backend::{BackendConfig, pprof::PprofConfig, pprof_backend};
use pyroscope::pyroscope::{PyroscopeAgent, PyroscopeAgentBuilder, PyroscopeAgentRunning};
use tracing::{info, warn};

use super::config::{ResolvedTelemetryConfig, RuntimeService};

const PYROSCOPE_SAMPLE_RATE_HZ: u32 = 100;
const PYROSCOPE_REACHABILITY_TIMEOUT: Duration = Duration::from_millis(500);

type RunningAgent = PyroscopeAgent<PyroscopeAgentRunning>;

#[derive(Debug, Clone, PartialEq, Eq)]
struct DaemonProfilerSettings {
    url: String,
    application_name: &'static str,
    tags: Vec<(&'static str, String)>,
}

pub struct DaemonProfiler {
    running: Option<RunningAgent>,
}

impl DaemonProfiler {
    #[must_use]
    pub const fn disabled() -> Self {
        Self { running: None }
    }

    #[must_use]
    pub const fn is_enabled(&self) -> bool {
        self.running.is_some()
    }

    #[must_use]
    pub fn start(service: RuntimeService, export: &ResolvedTelemetryConfig) -> Self {
        daemon_profiler_settings(service, export).map_or_else(Self::disabled, |settings| {
            Self::start_with_settings(service, &settings)
        })
    }

    pub fn shutdown(&mut self) {
        if let Some(running) = self.running.take() {
            shutdown_running_agent(running);
        }
    }

    fn start_with_settings(service: RuntimeService, settings: &DaemonProfilerSettings) -> Self {
        build_running_agent(settings).map_or_else(
            |error| Self::start_failed(service, settings, &error),
            |running| Self::start_succeeded(service, settings, running),
        )
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn start_succeeded(
        service: RuntimeService,
        settings: &DaemonProfilerSettings,
        running: RunningAgent,
    ) -> Self {
        info!(
            pyroscope_url = %settings.url,
            service_name = service.service_name(),
            "started daemon profiler"
        );
        Self {
            running: Some(running),
        }
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn start_failed(
        service: RuntimeService,
        settings: &DaemonProfilerSettings,
        error: &PyroscopeError,
    ) -> Self {
        warn!(
            %error,
            pyroscope_url = %settings.url,
            service_name = service.service_name(),
            "failed to start daemon profiler"
        );
        Self::disabled()
    }
}

fn daemon_profiler_settings(
    service: RuntimeService,
    export: &ResolvedTelemetryConfig,
) -> Option<DaemonProfilerSettings> {
    if service != RuntimeService::Daemon {
        return None;
    }

    let url = export.pyroscope_url.clone()?;
    if !pyroscope_endpoint_reachable(&url, PYROSCOPE_REACHABILITY_TIMEOUT) {
        info!(
            pyroscope_url = %url,
            timeout_ms = u64::try_from(PYROSCOPE_REACHABILITY_TIMEOUT.as_millis()).unwrap_or(u64::MAX),
            "pyroscope endpoint unreachable, skipping daemon profiler"
        );
        return None;
    }
    Some(DaemonProfilerSettings {
        url,
        application_name: service.service_name(),
        tags: vec![
            ("service_namespace", "harness".to_string()),
            ("service_version", env!("CARGO_PKG_VERSION").to_string()),
        ],
    })
}

// Probes the pyroscope server with a short TCP connect so we don't start the
// background pusher when the user has OTel configured but no live pyroscope -
// otherwise the agent floods the daemon log with `Failed to send session`
// every 10 s and steals CPU from the profiler thread.
fn pyroscope_endpoint_reachable(url: &str, timeout: Duration) -> bool {
    let Some(authority) = parse_authority(url) else {
        return false;
    };
    let addrs: Vec<SocketAddr> = match authority.to_socket_addrs() {
        Ok(iter) => iter.collect(),
        Err(_) => return false,
    };
    addrs
        .into_iter()
        .any(|addr| TcpStream::connect_timeout(&addr, timeout).is_ok())
}

// Extract the `host:port` slice from a `scheme://host[:port][/path]` URL,
// defaulting the port from the scheme when none is supplied.
fn parse_authority(url: &str) -> Option<String> {
    let after_scheme = url.split_once("://").map(|(scheme, rest)| (scheme, rest))?;
    let (scheme, rest) = after_scheme;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    if authority.is_empty() {
        return None;
    }
    if authority.contains(':') {
        return Some(authority.to_string());
    }
    let default_port = match scheme {
        "https" => 443,
        _ => 80,
    };
    Some(format!("{authority}:{default_port}"))
}

fn build_running_agent(settings: &DaemonProfilerSettings) -> Result<RunningAgent, PyroscopeError> {
    let tags = settings
        .tags
        .iter()
        .map(|(key, value)| (*key, value.as_str()))
        .collect::<Vec<_>>();
    let backend = pprof_backend(
        PprofConfig {
            sample_rate: PYROSCOPE_SAMPLE_RATE_HZ,
        },
        BackendConfig::default(),
    );
    let agent = PyroscopeAgentBuilder::new(
        &settings.url,
        settings.application_name,
        PYROSCOPE_SAMPLE_RATE_HZ,
        "pyroscope-rs",
        "2.0.0",
        backend,
    )
    .tags(tags)
    .build()?;
    agent.start()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn shutdown_running_agent(running: RunningAgent) {
    if let Err(error) = stop_running_agent(running) {
        warn!(%error, "failed to stop daemon profiler cleanly");
    }
}

fn stop_running_agent(running: RunningAgent) -> Result<(), PyroscopeError> {
    let ready = running.stop()?;
    ready.shutdown();
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::telemetry::config::{ExportProtocol, TelemetryConfigSource};

    fn export(pyroscope_url: Option<&str>) -> ResolvedTelemetryConfig {
        ResolvedTelemetryConfig {
            source: TelemetryConfigSource::SharedFile,
            protocol: ExportProtocol::Grpc,
            endpoint: "http://127.0.0.1:4317".to_string(),
            grafana_url: Some("http://127.0.0.1:3000".to_string()),
            pyroscope_url: pyroscope_url.map(ToOwned::to_owned),
            headers: BTreeMap::new(),
        }
    }

    #[test]
    fn daemon_profiler_settings_skip_non_daemon_services() {
        assert_eq!(
            daemon_profiler_settings(RuntimeService::Cli, &export(Some("http://127.0.0.1:4040"))),
            None
        );
    }

    #[test]
    fn daemon_profiler_settings_require_pyroscope_url() {
        assert_eq!(
            daemon_profiler_settings(RuntimeService::Daemon, &export(None)),
            None
        );
    }

    #[test]
    fn parse_authority_extracts_host_port_with_path() {
        assert_eq!(
            parse_authority("http://127.0.0.1:4040/push"),
            Some("127.0.0.1:4040".to_string())
        );
    }

    #[test]
    fn parse_authority_defaults_port_from_scheme() {
        assert_eq!(
            parse_authority("https://pyroscope.example.com/api"),
            Some("pyroscope.example.com:443".to_string())
        );
        assert_eq!(
            parse_authority("http://pyroscope.example.com"),
            Some("pyroscope.example.com:80".to_string())
        );
    }

    #[test]
    fn parse_authority_rejects_missing_scheme() {
        assert_eq!(parse_authority("127.0.0.1:4040"), None);
    }

    #[test]
    fn pyroscope_unreachable_endpoint_skips_settings() {
        // 127.0.0.1:1 is reserved and unbound on practically every host.
        let unreachable = "http://127.0.0.1:1";
        assert!(!pyroscope_endpoint_reachable(
            unreachable,
            Duration::from_millis(50)
        ));
        assert_eq!(
            daemon_profiler_settings(RuntimeService::Daemon, &export(Some(unreachable))),
            None
        );
    }

    #[test]
    fn daemon_profiler_settings_use_daemon_labels() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let url = format!("http://{}", listener.local_addr().expect("addr"));
        let settings =
            daemon_profiler_settings(RuntimeService::Daemon, &export(Some(&url))).expect("settings");

        assert_eq!(settings.url, url);
        assert_eq!(settings.application_name, "harness-daemon");
        assert_eq!(
            settings.tags,
            vec![
                ("service_namespace", "harness".to_string()),
                ("service_version", env!("CARGO_PKG_VERSION").to_string()),
            ]
        );
    }
}
