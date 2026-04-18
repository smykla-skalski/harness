use std::collections::{BTreeMap, HashMap};
use std::env;
use std::fmt::Display;
use std::io;
#[cfg(feature = "tokio-console")]
use std::net::SocketAddr;

use opentelemetry::KeyValue;
use opentelemetry::global;
use opentelemetry::trace::TracerProvider as _;
use opentelemetry_appender_tracing::layer::OpenTelemetryTracingBridge;
use opentelemetry_otlp::{Protocol, WithExportConfig, WithHttpConfig, WithTonicConfig};
use opentelemetry_sdk::Resource;
use opentelemetry_sdk::logs::SdkLoggerProvider;
use opentelemetry_sdk::metrics::SdkMeterProvider;
use opentelemetry_sdk::trace::{RandomIdGenerator, Sampler, SdkTracerProvider};
use tokio::runtime::{Builder as TokioRuntimeBuilder, Runtime as TokioRuntime};
use tonic::metadata::{MetadataKey, MetadataMap, MetadataValue};
use tracing_subscriber::filter::filter_fn;
use tracing_subscriber::fmt;
use tracing_subscriber::fmt::time::ChronoUtc;
use tracing_subscriber::prelude::*;
#[cfg(feature = "tokio-console")]
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::reload;

use crate::errors::{CliError, CliErrorKind};

use super::config::{
    ExportProtocol, ResolvedTelemetryConfig, RuntimeService, resolve_telemetry_config,
    runtime_service_from_current_process,
};
use super::metrics::install_text_map_propagator;
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

    fn disabled(service: RuntimeService) -> Self {
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

    fn enabled(
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

    fn shutdown(&self) {
        let _runtime_guard = self.async_runtime.as_ref().map(TokioRuntime::enter);
        if let Some(tracer_provider) = self.tracer_provider.as_ref() {
            let _ = tracer_provider.shutdown();
        }
        if let Some(meter_provider) = self.meter_provider.as_ref() {
            let _ = meter_provider.shutdown();
        }
        if let Some(logger_provider) = self.logger_provider.as_ref() {
            let _ = logger_provider.shutdown();
        }
    }
}

impl Drop for TelemetryGuard {
    fn drop(&mut self) {
        self.daemon_profiler.shutdown();
        self.shutdown();
    }
}

/// # Errors
///
/// Returns an error when telemetry export configuration cannot be resolved or
/// when the tracing subscriber cannot be initialized.
pub fn init_tracing_subscriber() -> Result<TelemetryGuard, CliError> {
    let filter = crate::resolved_log_filter_from_env();
    let (filter_layer, handle) = reload::Layer::new(filter);
    crate::set_log_filter_handle(handle);

    let use_json_format = env::var("HARNESS_LOG_FORMAT").ok().as_deref() == Some("json");
    let service = runtime_service_from_current_process();
    let export = resolve_telemetry_config()?;

    if let Some(export) = export {
        init_subscriber_with_telemetry(filter_layer, use_json_format, service, export)
    } else {
        init_subscriber_without_telemetry(filter_layer, use_json_format)?;
        Ok(TelemetryGuard::disabled(service))
    }
}

#[cfg(feature = "tokio-console")]
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn build_console_layer<S>() -> Option<Box<dyn tracing_subscriber::Layer<S> + Send + Sync + 'static>>
where
    S: tracing::Subscriber + for<'a> LookupSpan<'a>,
{
    if env::var("HARNESS_TOKIO_CONSOLE").ok().as_deref() != Some("1") {
        return None;
    }
    let addr: SocketAddr = env::var("HARNESS_TOKIO_CONSOLE_ADDR")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(|| ([127, 0, 0, 1], 6669).into());
    tracing::info!(%addr, "tokio-console server starting");
    Some(Box::new(
        console_subscriber::ConsoleLayer::builder()
            .server_addr(addr)
            .spawn(),
    ))
}

fn init_subscriber_without_telemetry(
    filter_layer: reload::Layer<tracing_subscriber::EnvFilter, tracing_subscriber::Registry>,
    use_json_format: bool,
) -> Result<(), CliError> {
    #[cfg(feature = "tokio-console")]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> = build_console_layer();
    #[cfg(not(feature = "tokio-console"))]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> = None;

    if use_json_format {
        tracing_subscriber::registry()
            .with(filter_layer)
            .with(console_layer)
            .with(
                fmt::layer()
                    .json()
                    .with_writer(io::stderr),
            )
            .try_init()
            .map_err(|error| CliErrorKind::workflow_io(format!("initialize tracing subscriber: {error}")).into())
    } else {
        tracing_subscriber::registry()
            .with(filter_layer)
            .with(console_layer)
            .with(
                fmt::layer()
                    .with_writer(io::stderr)
                    .with_target(false)
                    .with_timer(ChronoUtc::rfc_3339()),
            )
            .try_init()
            .map_err(|error| CliErrorKind::workflow_io(format!("initialize tracing subscriber: {error}")).into())
    }
}

fn init_subscriber_with_telemetry(
    filter_layer: reload::Layer<tracing_subscriber::EnvFilter, tracing_subscriber::Registry>,
    use_json_format: bool,
    service: RuntimeService,
    export: ResolvedTelemetryConfig,
) -> Result<TelemetryGuard, CliError> {
    let resource = telemetry_resource(service);
    let (async_runtime, tracer_provider, meter_provider, logger_provider) =
        build_export_providers(&export, resource)?;

    install_text_map_propagator();
    global::set_tracer_provider(tracer_provider.clone());
    global::set_meter_provider(meter_provider.clone());

    #[cfg(feature = "tokio-console")]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> = build_console_layer();
    #[cfg(not(feature = "tokio-console"))]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> = None;

    if use_json_format {
        let otel_trace_layer =
            tracing_opentelemetry::layer().with_tracer(tracer_provider.tracer(service.service_name()));
        let otel_log_layer =
            OpenTelemetryTracingBridge::new(&logger_provider)
                .with_filter(filter_fn(|metadata| metadata.target().starts_with("harness")));
        tracing_subscriber::registry()
            .with(filter_layer)
            .with(console_layer)
            .with(
                fmt::layer()
                    .json()
                    .with_writer(io::stderr),
            )
            .with(otel_trace_layer)
            .with(otel_log_layer)
            .try_init()
            .map_err(|error| CliErrorKind::workflow_io(format!("initialize tracing subscriber: {error}")))?;
    } else {
        let otel_trace_layer =
            tracing_opentelemetry::layer().with_tracer(tracer_provider.tracer(service.service_name()));
        let otel_log_layer =
            OpenTelemetryTracingBridge::new(&logger_provider)
                .with_filter(filter_fn(|metadata| metadata.target().starts_with("harness")));
        tracing_subscriber::registry()
            .with(filter_layer)
            .with(console_layer)
            .with(
                fmt::layer()
                    .with_writer(io::stderr)
                    .with_target(false)
                    .with_timer(ChronoUtc::rfc_3339()),
            )
            .with(otel_trace_layer)
            .with(otel_log_layer)
            .try_init()
            .map_err(|error| CliErrorKind::workflow_io(format!("initialize tracing subscriber: {error}")))?;
    }

    let daemon_profiler = DaemonProfiler::start(service, &export);

    Ok(TelemetryGuard::enabled(
        service,
        export,
        async_runtime,
        tracer_provider,
        meter_provider,
        logger_provider,
        daemon_profiler,
    ))
}

fn build_export_providers(
    export: &ResolvedTelemetryConfig,
    resource: Resource,
) -> Result<(TokioRuntime, SdkTracerProvider, SdkMeterProvider, SdkLoggerProvider), CliError> {
    let async_runtime = TokioRuntimeBuilder::new_multi_thread()
        .enable_all()
        .thread_name("harness-telemetry")
        .build()
        .map_err(|error| telemetry_setup_error("build telemetry runtime", error))?;

    let tracer_provider;
    let meter_provider;
    let logger_provider;
    {
        let _runtime_guard = async_runtime.enter();
        tracer_provider = build_tracer_provider(export, resource.clone())?;
        meter_provider = build_meter_provider(export, resource.clone())?;
        logger_provider = build_logger_provider(export, resource)?;
    }

    Ok((async_runtime, tracer_provider, meter_provider, logger_provider))
}

fn build_tracer_provider(
    export: &ResolvedTelemetryConfig,
    resource: Resource,
) -> Result<SdkTracerProvider, CliError> {
    let exporter = match export.protocol {
        ExportProtocol::Grpc => {
            let mut builder = opentelemetry_otlp::SpanExporter::builder()
                .with_tonic()
                .with_endpoint(export.endpoint.clone());
            if !export.headers.is_empty() {
                builder = builder.with_metadata(tonic_metadata(&export.headers)?);
            }
            builder
                .build()
                .map_err(|error| telemetry_setup_error("build OTLP trace exporter", error))?
        }
        ExportProtocol::HttpProtobuf => {
            let mut builder = opentelemetry_otlp::SpanExporter::builder()
                .with_http()
                .with_protocol(Protocol::HttpBinary)
                .with_endpoint(signal_http_endpoint(&export.endpoint, "/v1/traces"));
            if !export.headers.is_empty() {
                builder = builder.with_headers(export.headers.clone().into_iter().collect::<HashMap<_, _>>());
            }
            builder
                .build()
                .map_err(|error| telemetry_setup_error("build OTLP trace exporter", error))?
        }
    };

    Ok(SdkTracerProvider::builder()
        .with_sampler(Sampler::ParentBased(Box::new(Sampler::AlwaysOn)))
        .with_id_generator(RandomIdGenerator::default())
        .with_resource(resource)
        .with_batch_exporter(exporter)
        .build())
}

fn build_meter_provider(
    export: &ResolvedTelemetryConfig,
    resource: Resource,
) -> Result<SdkMeterProvider, CliError> {
    let exporter = match export.protocol {
        ExportProtocol::Grpc => {
            let mut builder = opentelemetry_otlp::MetricExporter::builder()
                .with_tonic()
                .with_endpoint(export.endpoint.clone());
            if !export.headers.is_empty() {
                builder = builder.with_metadata(tonic_metadata(&export.headers)?);
            }
            builder
                .build()
                .map_err(|error| telemetry_setup_error("build OTLP metric exporter", error))?
        }
        ExportProtocol::HttpProtobuf => {
            let mut builder = opentelemetry_otlp::MetricExporter::builder()
                .with_http()
                .with_protocol(Protocol::HttpBinary)
                .with_endpoint(signal_http_endpoint(&export.endpoint, "/v1/metrics"));
            if !export.headers.is_empty() {
                builder = builder.with_headers(export.headers.clone().into_iter().collect::<HashMap<_, _>>());
            }
            builder
                .build()
                .map_err(|error| telemetry_setup_error("build OTLP metric exporter", error))?
        }
    };

    Ok(SdkMeterProvider::builder()
        .with_resource(resource)
        .with_periodic_exporter(exporter)
        .build())
}

fn build_logger_provider(
    export: &ResolvedTelemetryConfig,
    resource: Resource,
) -> Result<SdkLoggerProvider, CliError> {
    let exporter = match export.protocol {
        ExportProtocol::Grpc => {
            let mut builder = opentelemetry_otlp::LogExporter::builder()
                .with_tonic()
                .with_endpoint(export.endpoint.clone());
            if !export.headers.is_empty() {
                builder = builder.with_metadata(tonic_metadata(&export.headers)?);
            }
            builder
                .build()
                .map_err(|error| telemetry_setup_error("build OTLP log exporter", error))?
        }
        ExportProtocol::HttpProtobuf => {
            let mut builder = opentelemetry_otlp::LogExporter::builder()
                .with_http()
                .with_protocol(Protocol::HttpBinary)
                .with_endpoint(signal_http_endpoint(&export.endpoint, "/v1/logs"));
            if !export.headers.is_empty() {
                builder = builder.with_headers(export.headers.clone().into_iter().collect::<HashMap<_, _>>());
            }
            builder
                .build()
                .map_err(|error| telemetry_setup_error("build OTLP log exporter", error))?
        }
    };

    Ok(SdkLoggerProvider::builder()
        .with_resource(resource)
        .with_batch_exporter(exporter)
        .build())
}

fn telemetry_resource(service: RuntimeService) -> Resource {
    Resource::builder()
        .with_service_name(service.service_name())
        .with_attributes([
            KeyValue::new("service.namespace", "harness"),
            KeyValue::new("service.version", env!("CARGO_PKG_VERSION")),
            KeyValue::new("deployment.environment.name", "local"),
        ])
        .build()
}

fn signal_http_endpoint(base: &str, suffix: &str) -> String {
    let trimmed = base.trim_end_matches('/');
    if trimmed.ends_with(suffix) || trimmed.contains("/v1/") {
        return trimmed.to_string();
    }
    format!("{trimmed}{suffix}")
}

fn tonic_metadata(headers: &BTreeMap<String, String>) -> Result<MetadataMap, CliError> {
    let mut metadata = MetadataMap::new();
    for (key, value) in headers {
        let metadata_key = MetadataKey::from_bytes(key.as_bytes()).map_err(|error| {
            CliErrorKind::workflow_io(format!("invalid OTLP metadata key `{key}`: {error}"))
        })?;
        let metadata_value = MetadataValue::try_from(value.as_str()).map_err(|error| {
            CliErrorKind::workflow_io(format!("invalid OTLP metadata value for `{key}`: {error}"))
        })?;
        metadata.insert(metadata_key, metadata_value);
    }
    Ok(metadata)
}

fn telemetry_setup_error(
    operation: &str,
    error: impl Display,
) -> CliError {
    CliErrorKind::workflow_io(format!("{operation}: {error}")).into()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::telemetry::config::TelemetryConfigSource;

    #[test]
    fn grpc_exporters_initialize_without_existing_tokio_runtime() {
        let export = ResolvedTelemetryConfig {
            source: TelemetryConfigSource::Environment,
            protocol: ExportProtocol::Grpc,
            endpoint: "http://127.0.0.1:4317".to_string(),
            grafana_url: None,
            pyroscope_url: None,
            headers: BTreeMap::new(),
        };
        let resource = telemetry_resource(RuntimeService::Cli);

        let result = std::panic::catch_unwind(|| {
            let (_runtime, _tracer, _meter, _logger) =
                build_export_providers(&export, resource).expect("providers");
        });

        assert!(
            result.is_ok(),
            "OTLP gRPC exporters should not require an existing Tokio runtime"
        );
    }
}
