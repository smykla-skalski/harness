use opentelemetry_sdk::logs::SdkLoggerProvider;
use opentelemetry_sdk::metrics::SdkMeterProvider;
use opentelemetry_sdk::trace::SdkTracerProvider;
use tokio::runtime::Runtime as TokioRuntime;

use super::config::{ResolvedTelemetryConfig, RuntimeService};
use super::profiler::DaemonProfiler;

pub struct TelemetryGuard {
    async_runtime: Option<TokioRuntime>,
    tracer_provider: Option<SdkTracerProvider>,
    meter_provider: Option<SdkMeterProvider>,
    logger_provider: Option<SdkLoggerProvider>,
    daemon_profiler: DaemonProfiler,
    export: Option<ResolvedTelemetryConfig>,
    service: RuntimeService,
}

impl TelemetryGuard {
    #[must_use]
    pub const fn service(&self) -> RuntimeService {
        self.service
    }

    #[must_use]
    pub fn export_config(&self) -> Option<&ResolvedTelemetryConfig> {
        self.export.as_ref()
    }

    pub(crate) fn disabled(service: RuntimeService) -> Self {
        Self {
            async_runtime: None,
            tracer_provider: None,
            meter_provider: None,
            logger_provider: None,
            daemon_profiler: DaemonProfiler::disabled(),
            export: None,
            service,
        }
    }

    pub(crate) fn enabled(
        service: RuntimeService,
        export: ResolvedTelemetryConfig,
        async_runtime: TokioRuntime,
        tracer_provider: SdkTracerProvider,
        meter_provider: SdkMeterProvider,
        logger_provider: SdkLoggerProvider,
        daemon_profiler: DaemonProfiler,
    ) -> Self {
        Self {
            async_runtime: Some(async_runtime),
            tracer_provider: Some(tracer_provider),
            meter_provider: Some(meter_provider),
            logger_provider: Some(logger_provider),
            daemon_profiler,
            export: Some(export),
            service,
        }
    }
}

impl Drop for TelemetryGuard {
    fn drop(&mut self) {
        self.daemon_profiler.shutdown();

        // Enter the telemetry runtime before dropping providers. Fields drop in
        // declaration order after drop() returns, so async_runtime (first field)
        // would be gone before tracer_provider etc. — tonic channels inside the
        // providers signal their background tasks during Drop and need a live reactor.
        // Taking the providers here drops them while the reactor is still registered.
        let _runtime_guard = self.async_runtime.as_ref().map(TokioRuntime::enter);

        if let Some(p) = self.tracer_provider.take() {
            let _ = p.shutdown();
        }
        if let Some(p) = self.meter_provider.take() {
            let _ = p.shutdown();
        }
        if let Some(p) = self.logger_provider.take() {
            let _ = p.shutdown();
        }
        // _runtime_guard drops here (locals drop in reverse declaration order).
        // async_runtime drops when the struct fields drop after this returns;
        // by then all providers are None so no reactor access is needed.
    }
}
