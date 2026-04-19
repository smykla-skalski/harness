use pyroscope::PyroscopeError;
use pyroscope::backend::{BackendConfig, pprof::PprofConfig, pprof_backend};
use pyroscope::pyroscope::{PyroscopeAgent, PyroscopeAgentBuilder, PyroscopeAgentRunning};
use tracing::{info, warn};

use super::config::{ResolvedTelemetryConfig, RuntimeService};

const PYROSCOPE_SAMPLE_RATE_HZ: u32 = 100;

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
    Some(DaemonProfilerSettings {
        url,
        application_name: service.service_name(),
        tags: vec![
            ("service_namespace", "harness".to_string()),
            ("service_version", env!("CARGO_PKG_VERSION").to_string()),
        ],
    })
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
    fn daemon_profiler_settings_use_daemon_labels() {
        let settings = daemon_profiler_settings(
            RuntimeService::Daemon,
            &export(Some("http://127.0.0.1:4040")),
        )
        .expect("settings");

        assert_eq!(settings.url, "http://127.0.0.1:4040");
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
