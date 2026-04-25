use std::collections::{BTreeMap, HashMap};
use std::fmt::Display;

use opentelemetry::KeyValue;
use opentelemetry_otlp::{Protocol, WithExportConfig, WithHttpConfig, WithTonicConfig};
use opentelemetry_sdk::Resource;
use opentelemetry_sdk::logs::SdkLoggerProvider;
use opentelemetry_sdk::metrics::SdkMeterProvider;
use opentelemetry_sdk::trace::{RandomIdGenerator, Sampler, SdkTracerProvider};
use tokio::runtime::{Builder as TokioRuntimeBuilder, Runtime as TokioRuntime};
use tonic::metadata::{MetadataKey, MetadataMap, MetadataValue};

use crate::errors::{CliError, CliErrorKind};

use super::config::{ExportProtocol, ResolvedTelemetryConfig, RuntimeService};

pub(crate) fn build_export_providers(
    export: &ResolvedTelemetryConfig,
    resource: Resource,
) -> Result<
    (
        TokioRuntime,
        SdkTracerProvider,
        SdkMeterProvider,
        SdkLoggerProvider,
    ),
    CliError,
> {
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

    Ok((
        async_runtime,
        tracer_provider,
        meter_provider,
        logger_provider,
    ))
}

pub(crate) fn telemetry_resource(service: RuntimeService) -> Resource {
    Resource::builder()
        .with_service_name(service.service_name())
        .with_attributes([
            KeyValue::new("service.namespace", "harness"),
            KeyValue::new("service.version", env!("CARGO_PKG_VERSION")),
            KeyValue::new("deployment.environment.name", "local"),
            KeyValue::new("deployment.env", "local"),
        ])
        .build()
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
                builder = builder.with_headers(
                    export
                        .headers
                        .clone()
                        .into_iter()
                        .collect::<HashMap<_, _>>(),
                );
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
                builder = builder.with_headers(
                    export
                        .headers
                        .clone()
                        .into_iter()
                        .collect::<HashMap<_, _>>(),
                );
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
                builder = builder.with_headers(
                    export
                        .headers
                        .clone()
                        .into_iter()
                        .collect::<HashMap<_, _>>(),
                );
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

fn telemetry_setup_error(operation: &str, error: impl Display) -> CliError {
    CliErrorKind::workflow_io(format!("{operation}: {error}")).into()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::telemetry::config::TelemetryConfigSource;

    fn grpc_export_config() -> ResolvedTelemetryConfig {
        ResolvedTelemetryConfig {
            source: TelemetryConfigSource::Environment,
            protocol: ExportProtocol::Grpc,
            endpoint: "http://127.0.0.1:4317".to_string(),
            grafana_url: None,
            pyroscope_url: None,
            headers: BTreeMap::new(),
        }
    }

    #[test]
    fn grpc_exporters_initialize_without_existing_tokio_runtime() {
        let result = std::panic::catch_unwind(|| {
            let (_runtime, _tracer, _meter, _logger) =
                build_export_providers(&grpc_export_config(), telemetry_resource(RuntimeService::Cli))
                    .expect("providers");
        });

        assert!(
            result.is_ok(),
            "OTLP gRPC exporters should not require an existing Tokio runtime"
        );
    }

    #[test]
    fn grpc_providers_drop_without_panic_after_shutdown() {
        // Regression: async_runtime was declared first in TelemetryGuard so it
        // dropped before tracer/meter/logger_provider. The tonic channels inside
        // those providers call tokio internals during Drop (to signal their
        // background connection tasks), which panicked when the reactor was gone.
        let result = std::panic::catch_unwind(|| {
            let (runtime, tracer, meter, logger) =
                build_export_providers(&grpc_export_config(), telemetry_resource(RuntimeService::Cli))
                    .expect("providers");
            // Mimic the old (broken) drop order: runtime first, then providers.
            drop(runtime);
            drop(tracer);
            drop(meter);
            drop(logger);
        });

        assert!(
            result.is_ok(),
            "providers should not panic when the runtime drops before they do"
        );
    }

    #[test]
    fn telemetry_resource_keeps_semantic_and_legacy_environment_labels() {
        let resource = telemetry_resource(RuntimeService::Cli);

        assert_eq!(
            resource
                .get(&opentelemetry::Key::from_static_str(
                    "deployment.environment.name"
                ))
                .map(|value| value.to_string()),
            Some("local".to_string())
        );
        assert_eq!(
            resource
                .get(&opentelemetry::Key::from_static_str("deployment.env"))
                .map(|value| value.to_string()),
            Some("local".to_string())
        );
    }
}
