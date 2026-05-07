use std::env;
use std::fmt::Display;
use std::io;
#[cfg(feature = "tokio-console")]
use std::net::SocketAddr;
use std::time::Duration;

use opentelemetry::global;
use opentelemetry::trace::TracerProvider as _;
use opentelemetry_appender_tracing::layer::OpenTelemetryTracingBridge;
use opentelemetry_sdk::logs::SdkLoggerProvider;
use opentelemetry_sdk::trace::SdkTracerProvider;
use tracing_subscriber::filter::filter_fn;
use tracing_subscriber::fmt;
use tracing_subscriber::fmt::time::ChronoUtc;
use tracing_subscriber::prelude::*;
#[cfg(feature = "tokio-console")]
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::reload;

use crate::errors::{CliError, CliErrorKind};

use super::config::{
    ResolvedTelemetryConfig, RuntimeService, resolve_telemetry_config,
    runtime_service_from_current_process,
};
use super::console_fields::{FilteredDefaultFields, FilteredJsonFields};
use super::guard::TelemetryGuard;
use super::metrics::install_text_map_propagator;
use super::profiler::DaemonProfiler;
use super::providers::{build_export_providers, telemetry_resource};
use super::reachability::endpoint_reachable;

const OTLP_REACHABILITY_TIMEOUT: Duration = Duration::from_millis(500);

/// # Errors
///
/// Returns an error when telemetry export configuration cannot be resolved or
/// when the tracing subscriber cannot be initialized.
pub fn init_tracing_subscriber() -> Result<TelemetryGuard, CliError> {
    let service = runtime_service_from_current_process();
    let filter = crate::resolved_log_filter_for_service(service)?;
    let (filter_layer, handle) = reload::Layer::new(filter);
    crate::set_log_filter_handle(handle);

    let use_json_format = env::var("HARNESS_LOG_FORMAT").ok().as_deref() == Some("json");
    init_subscriber_with_resolved_export(
        filter_layer,
        use_json_format,
        service,
        resolve_telemetry_config()?,
    )
}

fn init_subscriber_with_resolved_export(
    filter_layer: reload::Layer<tracing_subscriber::EnvFilter, tracing_subscriber::Registry>,
    use_json_format: bool,
    service: RuntimeService,
    export: Option<ResolvedTelemetryConfig>,
) -> Result<TelemetryGuard, CliError> {
    let Some(export) = export else {
        return init_disabled_subscriber(filter_layer, use_json_format, service, None);
    };

    if should_enable_telemetry_export(service, &export) {
        init_subscriber_with_telemetry(filter_layer, use_json_format, service, export)
    } else {
        init_disabled_subscriber(
            filter_layer,
            use_json_format,
            service,
            Some("OTLP endpoint unreachable; telemetry disabled for this process"),
        )
    }
}

fn init_disabled_subscriber(
    filter_layer: reload::Layer<tracing_subscriber::EnvFilter, tracing_subscriber::Registry>,
    use_json_format: bool,
    service: RuntimeService,
    log_message: Option<&str>,
) -> Result<TelemetryGuard, CliError> {
    init_subscriber_without_telemetry(filter_layer, use_json_format)?;
    log_message.into_iter().for_each(log_telemetry_disable);
    Ok(TelemetryGuard::disabled(service))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score for a single info! call"
)]
fn log_telemetry_disable(log_message: &str) {
    tracing::info!("{log_message}");
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
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> =
        build_console_layer();
    #[cfg(not(feature = "tokio-console"))]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> = None;

    if use_json_format {
        tracing_subscriber::registry()
            .with(filter_layer)
            .with(console_layer)
            .with(
                fmt::layer()
                    .json()
                    .fmt_fields(FilteredJsonFields::new())
                    .with_writer(io::stderr),
            )
            .try_init()
            .map_err(tracing_init_error)
    } else {
        tracing_subscriber::registry()
            .with(filter_layer)
            .with(console_layer)
            .with(
                fmt::layer()
                    .fmt_fields(FilteredDefaultFields::new())
                    .with_writer(io::stderr)
                    .with_target(false)
                    .with_timer(ChronoUtc::rfc_3339()),
            )
            .try_init()
            .map_err(tracing_init_error)
    }
}

fn tracing_init_error(error: impl Display) -> CliError {
    CliErrorKind::workflow_io(format!("initialize tracing subscriber: {error}")).into()
}

fn init_json_telemetry_subscriber(
    filter_layer: reload::Layer<tracing_subscriber::EnvFilter, tracing_subscriber::Registry>,
    service: RuntimeService,
    tracer_provider: &SdkTracerProvider,
    logger_provider: &SdkLoggerProvider,
) -> Result<(), CliError> {
    #[cfg(feature = "tokio-console")]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> =
        build_console_layer();
    #[cfg(not(feature = "tokio-console"))]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> = None;

    let otel_trace_layer =
        tracing_opentelemetry::layer().with_tracer(tracer_provider.tracer(service.service_name()));
    let otel_log_layer =
        OpenTelemetryTracingBridge::new(logger_provider).with_filter(filter_fn(|metadata| {
            metadata.target().starts_with("harness")
        }));

    tracing_subscriber::registry()
        .with(filter_layer)
        .with(console_layer)
        .with(fmt::layer().json().with_writer(io::stderr))
        .with(otel_trace_layer)
        .with(otel_log_layer)
        .try_init()
        .map_err(tracing_init_error)
}

fn init_filtered_json_telemetry_subscriber(
    filter_layer: reload::Layer<tracing_subscriber::EnvFilter, tracing_subscriber::Registry>,
    service: RuntimeService,
    tracer_provider: &SdkTracerProvider,
    logger_provider: &SdkLoggerProvider,
) -> Result<(), CliError> {
    #[cfg(feature = "tokio-console")]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> =
        build_console_layer();
    #[cfg(not(feature = "tokio-console"))]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> = None;

    let otel_trace_layer =
        tracing_opentelemetry::layer().with_tracer(tracer_provider.tracer(service.service_name()));
    let otel_log_layer =
        OpenTelemetryTracingBridge::new(logger_provider).with_filter(filter_fn(|metadata| {
            metadata.target().starts_with("harness")
        }));

    tracing_subscriber::registry()
        .with(filter_layer)
        .with(console_layer)
        .with(
            fmt::layer()
                .json()
                .fmt_fields(FilteredJsonFields::new())
                .with_writer(io::stderr),
        )
        .with(otel_trace_layer)
        .with(otel_log_layer)
        .try_init()
        .map_err(tracing_init_error)
}

fn init_text_telemetry_subscriber(
    filter_layer: reload::Layer<tracing_subscriber::EnvFilter, tracing_subscriber::Registry>,
    service: RuntimeService,
    tracer_provider: &SdkTracerProvider,
    logger_provider: &SdkLoggerProvider,
) -> Result<(), CliError> {
    #[cfg(feature = "tokio-console")]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> =
        build_console_layer();
    #[cfg(not(feature = "tokio-console"))]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> = None;

    let otel_trace_layer =
        tracing_opentelemetry::layer().with_tracer(tracer_provider.tracer(service.service_name()));
    let otel_log_layer =
        OpenTelemetryTracingBridge::new(logger_provider).with_filter(filter_fn(|metadata| {
            metadata.target().starts_with("harness")
        }));

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
        .map_err(tracing_init_error)
}

fn init_filtered_text_telemetry_subscriber(
    filter_layer: reload::Layer<tracing_subscriber::EnvFilter, tracing_subscriber::Registry>,
    service: RuntimeService,
    tracer_provider: &SdkTracerProvider,
    logger_provider: &SdkLoggerProvider,
) -> Result<(), CliError> {
    #[cfg(feature = "tokio-console")]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> =
        build_console_layer();
    #[cfg(not(feature = "tokio-console"))]
    let console_layer: Option<Box<dyn tracing_subscriber::Layer<_> + Send + Sync>> = None;

    let otel_trace_layer =
        tracing_opentelemetry::layer().with_tracer(tracer_provider.tracer(service.service_name()));
    let otel_log_layer =
        OpenTelemetryTracingBridge::new(logger_provider).with_filter(filter_fn(|metadata| {
            metadata.target().starts_with("harness")
        }));

    tracing_subscriber::registry()
        .with(filter_layer)
        .with(console_layer)
        .with(
            fmt::layer()
                .fmt_fields(FilteredDefaultFields::new())
                .with_writer(io::stderr)
                .with_target(false)
                .with_timer(ChronoUtc::rfc_3339()),
        )
        .with(otel_trace_layer)
        .with(otel_log_layer)
        .try_init()
        .map_err(tracing_init_error)
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

    let show_observability_fields = show_console_observability_fields(service);
    if use_json_format {
        if show_observability_fields {
            init_json_telemetry_subscriber(
                filter_layer,
                service,
                &tracer_provider,
                &logger_provider,
            )?;
        } else {
            init_filtered_json_telemetry_subscriber(
                filter_layer,
                service,
                &tracer_provider,
                &logger_provider,
            )?;
        }
    } else {
        if show_observability_fields {
            init_text_telemetry_subscriber(
                filter_layer,
                service,
                &tracer_provider,
                &logger_provider,
            )?;
        } else {
            init_filtered_text_telemetry_subscriber(
                filter_layer,
                service,
                &tracer_provider,
                &logger_provider,
            )?;
        }
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

fn should_enable_telemetry_export(
    service: RuntimeService,
    export: &ResolvedTelemetryConfig,
) -> bool {
    !matches!(service, RuntimeService::Daemon | RuntimeService::Bridge)
        || endpoint_reachable(&export.endpoint, OTLP_REACHABILITY_TIMEOUT)
}

const fn show_console_observability_fields(service: RuntimeService) -> bool {
    matches!(service, RuntimeService::Daemon | RuntimeService::Bridge)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::telemetry::config::{ExportProtocol, TelemetryConfigSource};

    fn export(endpoint: &str) -> ResolvedTelemetryConfig {
        ResolvedTelemetryConfig {
            source: TelemetryConfigSource::Environment,
            protocol: ExportProtocol::Grpc,
            endpoint: endpoint.to_string(),
            grafana_url: None,
            pyroscope_url: None,
            headers: BTreeMap::new(),
        }
    }

    #[test]
    fn daemon_telemetry_requires_reachable_otlp_endpoint() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let reachable = export(&format!("http://{}", listener.local_addr().expect("addr")));

        assert!(should_enable_telemetry_export(
            RuntimeService::Daemon,
            &reachable
        ));
        assert!(!should_enable_telemetry_export(
            RuntimeService::Daemon,
            &export("http://127.0.0.1:1")
        ));
    }

    #[test]
    fn short_lived_services_do_not_probe_otlp_endpoint() {
        let unreachable = export("http://127.0.0.1:1");

        assert!(should_enable_telemetry_export(
            RuntimeService::Cli,
            &unreachable
        ));
        assert!(should_enable_telemetry_export(
            RuntimeService::Hook,
            &unreachable
        ));
    }

    #[test]
    fn console_observability_fields_only_show_for_long_lived_services() {
        assert!(show_console_observability_fields(RuntimeService::Daemon));
        assert!(show_console_observability_fields(RuntimeService::Bridge));
        assert!(!show_console_observability_fields(RuntimeService::Cli));
        assert!(!show_console_observability_fields(RuntimeService::Hook));
    }
}
