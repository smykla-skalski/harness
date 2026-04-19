use std::collections::BTreeMap;
use std::fs;
use std::future::Future;
use std::path::Path;
use std::sync::OnceLock;

use axum::http::HeaderMap;
use axum::http::header::HeaderName;
use opentelemetry::Context;
use opentelemetry::KeyValue;
use opentelemetry::baggage::BaggageExt as _;
use opentelemetry::global;
use opentelemetry::metrics::{Counter, Gauge, Histogram, Meter};
use opentelemetry::propagation::{Extractor, Injector, TextMapCompositePropagator};
use opentelemetry::trace::TraceContextExt as _;
use opentelemetry_sdk::propagation::{BaggagePropagator, TraceContextPropagator};
use tracing_opentelemetry::OpenTelemetrySpanExt;

static TELEMETRY_METER: OnceLock<Meter> = OnceLock::new();
static HOOK_DURATION_HISTOGRAM: OnceLock<Histogram<u64>> = OnceLock::new();
static HOOK_OUTCOME_COUNTER: OnceLock<Counter<u64>> = OnceLock::new();
static DAEMON_CLIENT_DURATION_HISTOGRAM: OnceLock<Histogram<u64>> = OnceLock::new();
static DAEMON_CLIENT_REQUEST_COUNTER: OnceLock<Counter<u64>> = OnceLock::new();
static DAEMON_HTTP_DURATION_HISTOGRAM: OnceLock<Histogram<u64>> = OnceLock::new();
static DAEMON_HTTP_REQUEST_COUNTER: OnceLock<Counter<u64>> = OnceLock::new();
static DAEMON_DB_DURATION_HISTOGRAM: OnceLock<Histogram<u64>> = OnceLock::new();
static DAEMON_DB_OPERATION_COUNTER: OnceLock<Counter<u64>> = OnceLock::new();
static DAEMON_DB_ERROR_COUNTER: OnceLock<Counter<u64>> = OnceLock::new();
static DAEMON_DB_BUSY_COUNTER: OnceLock<Counter<u64>> = OnceLock::new();
static DAEMON_DB_FILE_SIZE_GAUGE: OnceLock<Gauge<u64>> = OnceLock::new();
static DAEMON_DB_POOL_CONNECTION_GAUGE: OnceLock<Gauge<u64>> = OnceLock::new();
static DAEMON_DB_HEALTH_COUNT_GAUGE: OnceLock<Gauge<u64>> = OnceLock::new();

tokio::task_local! {
    static ACTIVE_TELEMETRY_BAGGAGE: TelemetryBaggage;
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TelemetryBaggage {
    session_id: Option<String>,
    project_id: Option<String>,
}

impl TelemetryBaggage {
    fn from_context(context: &Context) -> Self {
        Self {
            session_id: context.baggage().get("session.id").map(ToString::to_string),
            project_id: context.baggage().get("project.id").map(ToString::to_string),
        }
    }

    fn is_empty(&self) -> bool {
        self.session_id.is_none() && self.project_id.is_none()
    }

    fn apply_to_span(&self, span: &tracing::Span) {
        let span_context = span.context();
        let otel_span = span_context.span();
        if let Some(session_id) = &self.session_id {
            otel_span.set_attribute(KeyValue::new("session.id", session_id.clone()));
        }
        if let Some(project_id) = &self.project_id {
            otel_span.set_attribute(KeyValue::new("project.id", project_id.clone()));
        }
    }
}

pub fn install_text_map_propagator() {
    global::set_text_map_propagator(TextMapCompositePropagator::new(vec![
        Box::new(BaggagePropagator::new()),
        Box::new(TraceContextPropagator::new()),
    ]));
}

#[must_use]
pub fn current_trace_headers() -> BTreeMap<String, String> {
    let mut injector = HeaderInjector::default();
    let context = tracing::Span::current().context();
    global::get_text_map_propagator(|propagator| {
        propagator.inject_context(&context, &mut injector);
    });
    injector.headers
}

#[must_use]
pub fn apply_parent_context_from_headers(
    span: &tracing::Span,
    headers: &HeaderMap,
) -> TelemetryBaggage {
    let extractor = HeaderExtractor(headers);
    let context = global::get_text_map_propagator(|propagator| propagator.extract(&extractor));
    apply_remote_context_to_span(span, context)
}

#[must_use]
pub fn apply_parent_context_from_text_map(
    span: &tracing::Span,
    headers: &BTreeMap<String, String>,
) -> TelemetryBaggage {
    let extractor = TextMapExtractor(headers);
    let context = global::get_text_map_propagator(|propagator| propagator.extract(&extractor));
    apply_remote_context_to_span(span, context)
}

pub async fn with_active_baggage<T>(
    baggage: TelemetryBaggage,
    future: impl Future<Output = T>,
) -> T {
    if baggage.is_empty() {
        future.await
    } else {
        ACTIVE_TELEMETRY_BAGGAGE.scope(baggage, future).await
    }
}

pub fn apply_current_baggage_to_span(span: &tracing::Span) {
    if let Ok(baggage) = ACTIVE_TELEMETRY_BAGGAGE.try_with(Clone::clone) {
        baggage.apply_to_span(span);
        return;
    }

    let context = tracing::Span::current().context();
    TelemetryBaggage::from_context(&context).apply_to_span(span);
}

#[must_use]
pub fn current_trace_id() -> Option<String> {
    let context = tracing::Span::current().context();
    let span = context.span();
    let span_context = span.span_context();
    span_context
        .is_valid()
        .then(|| span_context.trace_id().to_string())
}

pub fn record_hook_metrics(hook_name: &str, event_name: &str, outcome: &str, duration_ms: u64) {
    let attributes = [
        KeyValue::new("hook.name", hook_name.to_string()),
        KeyValue::new("hook.event", event_name.to_string()),
        KeyValue::new("hook.outcome", outcome.to_string()),
    ];
    hook_duration_histogram().record(duration_ms, &attributes);
    hook_outcome_counter().add(1, &attributes);
}

pub fn record_daemon_client_metrics(
    method: &str,
    path: &str,
    status: u16,
    duration_ms: u64,
    is_error: bool,
) {
    let attributes = [
        KeyValue::new("http.method", method.to_string()),
        KeyValue::new("http.route", path.to_string()),
        KeyValue::new("http.status_code", i64::from(status)),
        KeyValue::new("error", is_error),
    ];
    daemon_client_duration_histogram().record(duration_ms, &attributes);
    daemon_client_request_counter().add(1, &attributes);
}

pub fn record_daemon_http_metrics(method: &str, path: &str, status: u16, duration_ms: u64) {
    let attributes = [
        KeyValue::new("http.method", method.to_string()),
        KeyValue::new("http.route", path.to_string()),
        KeyValue::new("http.status_code", i64::from(status)),
    ];
    daemon_http_duration_histogram().record(duration_ms, &attributes);
    daemon_http_request_counter().add(1, &attributes);
}

pub fn record_daemon_db_operation_metrics(
    operation: &str,
    engine: &str,
    access: &str,
    duration_ms: u64,
    is_error: bool,
    is_busy: bool,
    db_path: Option<&Path>,
) {
    let attributes = daemon_db_attributes(operation, engine, access, db_path);
    daemon_db_duration_histogram().record(duration_ms, &attributes);
    daemon_db_operation_counter().add(1, &attributes);
    if is_error {
        daemon_db_error_counter().add(1, &attributes);
    }
    if is_busy {
        daemon_db_busy_counter().add(1, &attributes);
    }
    if let Some(size_bytes) = sqlite_file_size_bytes(db_path) {
        daemon_db_file_size_gauge().record(
            size_bytes,
            &[
                KeyValue::new("db.system", "sqlite"),
                KeyValue::new("db.engine", engine.to_string()),
                KeyValue::new("db.file", db_file_label(db_path)),
            ],
        );
    }
}

pub fn record_daemon_db_pool_state(engine: &str, total_connections: u64, idle_connections: u64) {
    let in_use_connections = total_connections.saturating_sub(idle_connections);
    for (state, value) in [
        ("total", total_connections),
        ("idle", idle_connections),
        ("in_use", in_use_connections),
    ] {
        daemon_db_pool_connection_gauge().record(
            value,
            &[
                KeyValue::new("db.system", "sqlite"),
                KeyValue::new("db.engine", engine.to_string()),
                KeyValue::new("pool.state", state.to_string()),
            ],
        );
    }
}

pub fn record_daemon_db_health_counts(
    engine: &str,
    project_count: usize,
    worktree_count: usize,
    session_count: usize,
) {
    for (entity, value) in [
        ("projects", u64::try_from(project_count).unwrap_or(u64::MAX)),
        (
            "worktrees",
            u64::try_from(worktree_count).unwrap_or(u64::MAX),
        ),
        ("sessions", u64::try_from(session_count).unwrap_or(u64::MAX)),
    ] {
        daemon_db_health_count_gauge().record(
            value,
            &[
                KeyValue::new("db.system", "sqlite"),
                KeyValue::new("db.engine", engine.to_string()),
                KeyValue::new("db.entity", entity.to_string()),
            ],
        );
    }
}

fn telemetry_meter() -> &'static Meter {
    TELEMETRY_METER.get_or_init(|| global::meter("harness"))
}

fn apply_remote_context_to_span(span: &tracing::Span, context: Context) -> TelemetryBaggage {
    let baggage = TelemetryBaggage::from_context(&context);
    let _ = span.set_parent(context);
    baggage.apply_to_span(span);
    baggage
}

fn hook_duration_histogram() -> &'static Histogram<u64> {
    HOOK_DURATION_HISTOGRAM.get_or_init(|| {
        telemetry_meter()
            .u64_histogram("harness.hook.duration")
            .with_unit("ms")
            .build()
    })
}

fn hook_outcome_counter() -> &'static Counter<u64> {
    HOOK_OUTCOME_COUNTER.get_or_init(|| {
        telemetry_meter()
            .u64_counter("harness.hook.outcomes")
            .build()
    })
}

fn daemon_client_duration_histogram() -> &'static Histogram<u64> {
    DAEMON_CLIENT_DURATION_HISTOGRAM.get_or_init(|| {
        telemetry_meter()
            .u64_histogram("harness.daemon.client.duration")
            .with_unit("ms")
            .build()
    })
}

fn daemon_client_request_counter() -> &'static Counter<u64> {
    DAEMON_CLIENT_REQUEST_COUNTER.get_or_init(|| {
        telemetry_meter()
            .u64_counter("harness.daemon.client.requests")
            .build()
    })
}

fn daemon_http_duration_histogram() -> &'static Histogram<u64> {
    DAEMON_HTTP_DURATION_HISTOGRAM.get_or_init(|| {
        telemetry_meter()
            .u64_histogram("harness.daemon.http.duration")
            .with_unit("ms")
            .build()
    })
}

fn daemon_http_request_counter() -> &'static Counter<u64> {
    DAEMON_HTTP_REQUEST_COUNTER.get_or_init(|| {
        telemetry_meter()
            .u64_counter("harness.daemon.http.requests")
            .build()
    })
}

fn daemon_db_duration_histogram() -> &'static Histogram<u64> {
    DAEMON_DB_DURATION_HISTOGRAM.get_or_init(|| {
        telemetry_meter()
            .u64_histogram("harness.daemon.db.operation.duration")
            .with_unit("ms")
            .build()
    })
}

fn daemon_db_operation_counter() -> &'static Counter<u64> {
    DAEMON_DB_OPERATION_COUNTER.get_or_init(|| {
        telemetry_meter()
            .u64_counter("harness.daemon.db.operations")
            .build()
    })
}

fn daemon_db_error_counter() -> &'static Counter<u64> {
    DAEMON_DB_ERROR_COUNTER.get_or_init(|| {
        telemetry_meter()
            .u64_counter("harness.daemon.db.errors")
            .build()
    })
}

fn daemon_db_busy_counter() -> &'static Counter<u64> {
    DAEMON_DB_BUSY_COUNTER.get_or_init(|| {
        telemetry_meter()
            .u64_counter("harness.daemon.db.busy")
            .build()
    })
}

fn daemon_db_file_size_gauge() -> &'static Gauge<u64> {
    DAEMON_DB_FILE_SIZE_GAUGE.get_or_init(|| {
        telemetry_meter()
            .u64_gauge("harness.daemon.db.file_size_bytes")
            .build()
    })
}

fn daemon_db_pool_connection_gauge() -> &'static Gauge<u64> {
    DAEMON_DB_POOL_CONNECTION_GAUGE.get_or_init(|| {
        telemetry_meter()
            .u64_gauge("harness.daemon.db.pool.connections")
            .build()
    })
}

fn daemon_db_health_count_gauge() -> &'static Gauge<u64> {
    DAEMON_DB_HEALTH_COUNT_GAUGE.get_or_init(|| {
        telemetry_meter()
            .u64_gauge("harness.daemon.db.health.count")
            .build()
    })
}

fn daemon_db_attributes(
    operation: &str,
    engine: &str,
    access: &str,
    db_path: Option<&Path>,
) -> [KeyValue; 5] {
    [
        KeyValue::new("db.system", "sqlite"),
        KeyValue::new("db.engine", engine.to_string()),
        KeyValue::new("db.operation.name", operation.to_string()),
        KeyValue::new("db.access", access.to_string()),
        KeyValue::new("db.file", db_file_label(db_path)),
    ]
}

fn db_file_label(db_path: Option<&Path>) -> String {
    db_path
        .and_then(Path::file_name)
        .and_then(|file_name| file_name.to_str())
        .map_or_else(|| "memory".to_string(), ToOwned::to_owned)
}

fn sqlite_file_size_bytes(db_path: Option<&Path>) -> Option<u64> {
    let path = db_path?;
    let mut total = 0_u64;
    let base = path.as_os_str().to_owned();
    for suffix in ["", "-wal", "-shm"] {
        let candidate = if suffix.is_empty() {
            path.to_path_buf()
        } else {
            let mut value = base.clone();
            value.push(suffix);
            value.into()
        };
        if let Ok(metadata) = fs::metadata(candidate) {
            total = total.saturating_add(metadata.len());
        }
    }
    Some(total)
}

#[derive(Default)]
struct HeaderInjector {
    headers: BTreeMap<String, String>,
}

impl Injector for HeaderInjector {
    fn set(&mut self, key: &str, value: String) {
        self.headers.insert(key.to_string(), value);
    }
}

struct HeaderExtractor<'a>(&'a HeaderMap);

impl Extractor for HeaderExtractor<'_> {
    fn get(&self, key: &str) -> Option<&str> {
        self.0.get(key).and_then(|value| value.to_str().ok())
    }

    fn keys(&self) -> Vec<&str> {
        self.0.keys().map(HeaderName::as_str).collect()
    }
}

struct TextMapExtractor<'a>(&'a BTreeMap<String, String>);

impl Extractor for TextMapExtractor<'_> {
    fn get(&self, key: &str) -> Option<&str> {
        self.0.get(key).map(String::as_str)
    }

    fn keys(&self) -> Vec<&str> {
        self.0.keys().map(String::as_str).collect()
    }
}

#[cfg(test)]
mod tests {
    use opentelemetry::trace::TracerProvider as _;
    use opentelemetry_sdk::propagation::TraceContextPropagator;
    use opentelemetry_sdk::trace::SdkTracerProvider;
    use tracing_subscriber::prelude::*;

    use super::*;

    #[test]
    fn text_map_parent_context_preserves_trace_id() {
        let _guard = crate::telemetry::telemetry_test_guard();
        global::set_text_map_propagator(TraceContextPropagator::new());
        let tracer_provider = SdkTracerProvider::builder().build();
        let tracer = tracer_provider.tracer("metrics-tests");
        let subscriber =
            tracing_subscriber::registry().with(tracing_opentelemetry::layer().with_tracer(tracer));

        tracing::subscriber::with_default(subscriber, || {
            let root_span = tracing::info_span!("root");
            let _guard = root_span.enter();

            let headers = current_trace_headers();
            let root_trace_id = current_trace_id().expect("root trace id");

            let child_span = tracing::info_span!("child");
            let _ = apply_parent_context_from_text_map(&child_span, &headers);

            let child_trace_id =
                child_span.in_scope(|| current_trace_id().expect("child trace id"));

            assert_eq!(root_trace_id, child_trace_id);
        });

        let _ = tracer_provider.shutdown();
    }
}
