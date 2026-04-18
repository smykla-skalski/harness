use std::sync::{Arc, Mutex};

use opentelemetry::Value as OTelValue;
use opentelemetry::trace::{SpanKind, TracerProvider as _};
use opentelemetry_sdk::error::OTelSdkResult;
use opentelemetry_sdk::trace::{SdkTracerProvider, SpanData, SpanExporter};
use tracing_subscriber::prelude::*;

use super::connection::ConnectionState;
use super::dispatch::dispatch;
use super::test_support::test_http_state_with_async_db_timeline;
use crate::daemon::protocol::WsRequest;

#[tokio::test(flavor = "current_thread")]
async fn websocket_dispatch_uses_trace_context_parent_and_rpc_name() {
    let _guard = crate::telemetry::telemetry_test_guard();
    crate::telemetry::install_text_map_propagator();
    let exporter = TestSpanExporter::default();
    let tracer_provider = SdkTracerProvider::builder()
        .with_simple_exporter(exporter.clone())
        .build();
    let tracer = tracer_provider.tracer("daemon-websocket-tests");
    let subscriber =
        tracing_subscriber::registry().with(tracing_opentelemetry::layer().with_tracer(tracer));
    let _subscriber_guard = tracing::subscriber::set_default(subscriber);

    let state = test_http_state_with_async_db_timeline().await;
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let request = {
        let parent_span = tracing::info_span!("monitor.websocket.client", otel.kind = "client");
        let _parent_guard = parent_span.enter();
        WsRequest {
            id: "req-trace-context".into(),
            method: "session.detail".into(),
            params: serde_json::json!({ "session_id": "sess-test-1" }),
            trace_context: Some(crate::telemetry::current_trace_headers()),
        }
    };

    let response = dispatch(&request, &state, &connection).await;
    assert!(response.error.is_none());

    let _ = tracer_provider.force_flush();
    let spans = exporter.finished_spans();
    let parent_span = find_exported_span(&spans, "monitor.websocket.client");
    let rpc_span = find_exported_span(&spans, "session.detail");
    let db_span = find_exported_span(&spans, "daemon.db.async.resolve_session");

    assert_eq!(rpc_span.span_kind, SpanKind::Server);
    assert!(rpc_span.parent_span_is_remote);
    assert_eq!(rpc_span.parent_span_id, parent_span.span_context.span_id());
    assert_eq!(
        rpc_span.span_context.trace_id(),
        parent_span.span_context.trace_id()
    );
    assert_eq!(
        span_string_attribute(rpc_span, "rpc.system").as_deref(),
        Some("harness-daemon")
    );
    assert_eq!(
        span_string_attribute(rpc_span, "transport.kind").as_deref(),
        Some("websocket")
    );
    assert_eq!(db_span.span_kind, SpanKind::Client);
    assert_eq!(db_span.parent_span_id, rpc_span.span_context.span_id());
    assert_eq!(
        db_span.span_context.trace_id(),
        rpc_span.span_context.trace_id()
    );
    assert_eq!(
        span_string_attribute(db_span, "db.operation.name").as_deref(),
        Some("resolve_session")
    );
    assert_eq!(
        span_string_attribute(db_span, "db.system").as_deref(),
        Some("sqlite")
    );
}

#[tokio::test(flavor = "current_thread")]
async fn websocket_dispatch_projects_baggage_attributes_onto_rpc_and_db_spans() {
    let _guard = crate::telemetry::telemetry_test_guard();
    crate::telemetry::install_text_map_propagator();
    let exporter = TestSpanExporter::default();
    let tracer_provider = SdkTracerProvider::builder()
        .with_simple_exporter(exporter.clone())
        .build();
    let tracer = tracer_provider.tracer("daemon-websocket-tests");
    let subscriber =
        tracing_subscriber::registry().with(tracing_opentelemetry::layer().with_tracer(tracer));
    let _subscriber_guard = tracing::subscriber::set_default(subscriber);

    let state = test_http_state_with_async_db_timeline().await;
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let request = {
        let parent_span = tracing::info_span!("monitor.websocket.client", otel.kind = "client");
        let _parent_guard = parent_span.enter();
        let mut trace_context = crate::telemetry::current_trace_headers();
        trace_context.insert(
            "baggage".into(),
            "session.id=sess-test-1,project.id=proj-test-9".into(),
        );
        WsRequest {
            id: "req-baggage-context".into(),
            method: "session.detail".into(),
            params: serde_json::json!({ "session_id": "sess-test-1" }),
            trace_context: Some(trace_context),
        }
    };

    let response = dispatch(&request, &state, &connection).await;
    assert!(response.error.is_none());

    let _ = tracer_provider.force_flush();
    let spans = exporter.finished_spans();
    let rpc_span = find_exported_span(&spans, "session.detail");
    let db_span = find_exported_span(&spans, "daemon.db.async.resolve_session");

    assert_eq!(
        span_string_attribute(rpc_span, "session.id").as_deref(),
        Some("sess-test-1")
    );
    assert_eq!(
        span_string_attribute(rpc_span, "project.id").as_deref(),
        Some("proj-test-9")
    );
    assert_eq!(
        span_string_attribute(db_span, "session.id").as_deref(),
        Some("sess-test-1")
    );
    assert_eq!(
        span_string_attribute(db_span, "project.id").as_deref(),
        Some("proj-test-9")
    );
}

fn find_exported_span<'a>(spans: &'a [SpanData], name: &str) -> &'a SpanData {
    spans
        .iter()
        .find(|span| span.name.as_ref() == name)
        .unwrap_or_else(|| panic!("expected span named {name}, got {spans:#?}"))
}

fn span_string_attribute(span: &SpanData, key: &str) -> Option<String> {
    span.attributes
        .iter()
        .find(|attribute| attribute.key.as_str() == key)
        .and_then(|attribute| match &attribute.value {
            OTelValue::String(value) => Some(value.as_str().to_string()),
            _ => None,
        })
}

#[derive(Clone, Debug, Default)]
struct TestSpanExporter {
    spans: Arc<Mutex<Vec<SpanData>>>,
}

impl TestSpanExporter {
    fn finished_spans(&self) -> Vec<SpanData> {
        self.spans.lock().expect("span exporter lock").clone()
    }
}

impl SpanExporter for TestSpanExporter {
    fn export(
        &self,
        batch: Vec<SpanData>,
    ) -> impl std::future::Future<Output = OTelSdkResult> + Send {
        let spans = Arc::clone(&self.spans);
        async move {
            spans.lock().expect("span exporter lock").extend(batch);
            Ok(())
        }
    }
}
