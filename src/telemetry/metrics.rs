use std::collections::BTreeMap;
use std::sync::OnceLock;

use axum::http::HeaderMap;
use axum::http::header::HeaderName;
use opentelemetry::KeyValue;
use opentelemetry::global;
use opentelemetry::metrics::{Counter, Histogram, Meter};
use opentelemetry::propagation::{Extractor, Injector};
use opentelemetry::trace::TraceContextExt as _;
use tracing_opentelemetry::OpenTelemetrySpanExt;

static TELEMETRY_METER: OnceLock<Meter> = OnceLock::new();
static HOOK_DURATION_HISTOGRAM: OnceLock<Histogram<u64>> = OnceLock::new();
static HOOK_OUTCOME_COUNTER: OnceLock<Counter<u64>> = OnceLock::new();
static DAEMON_CLIENT_DURATION_HISTOGRAM: OnceLock<Histogram<u64>> = OnceLock::new();
static DAEMON_CLIENT_REQUEST_COUNTER: OnceLock<Counter<u64>> = OnceLock::new();
static DAEMON_HTTP_DURATION_HISTOGRAM: OnceLock<Histogram<u64>> = OnceLock::new();
static DAEMON_HTTP_REQUEST_COUNTER: OnceLock<Counter<u64>> = OnceLock::new();

#[must_use]
pub fn current_trace_headers() -> BTreeMap<String, String> {
    let mut injector = HeaderInjector::default();
    let context = tracing::Span::current().context();
    global::get_text_map_propagator(|propagator| {
        propagator.inject_context(&context, &mut injector);
    });
    injector.headers
}

pub fn apply_parent_context_from_headers(span: &tracing::Span, headers: &HeaderMap) {
    let extractor = HeaderExtractor(headers);
    let context = global::get_text_map_propagator(|propagator| propagator.extract(&extractor));
    let _ = span.set_parent(context);
}

pub fn apply_parent_context_from_text_map(
    span: &tracing::Span,
    headers: &BTreeMap<String, String>,
) {
    let extractor = TextMapExtractor(headers);
    let context = global::get_text_map_propagator(|propagator| propagator.extract(&extractor));
    let _ = span.set_parent(context);
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

fn telemetry_meter() -> &'static Meter {
    TELEMETRY_METER.get_or_init(|| global::meter("harness"))
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
            apply_parent_context_from_text_map(&child_span, &headers);

            let child_trace_id =
                child_span.in_scope(|| current_trace_id().expect("child trace id"));

            assert_eq!(root_trace_id, child_trace_id);
        });

        let _ = tracer_provider.shutdown();
    }
}
