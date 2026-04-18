use std::sync::{Arc, Mutex};

use axum::Router;
use axum::middleware;
use axum::routing::get;
use opentelemetry::Value as OTelValue;
use opentelemetry::global;
use opentelemetry::trace::{SpanKind, TracerProvider as _};
use opentelemetry_sdk::error::OTelSdkResult;
use opentelemetry_sdk::propagation::TraceContextPropagator;
use opentelemetry_sdk::trace::{SdkTracerProvider, SpanData, SpanExporter};
use tokio::net::TcpListener;
use tracing_subscriber::prelude::*;

#[tokio::test(flavor = "current_thread")]
async fn trace_http_request_uses_route_name_and_parent_trace_context() {
    global::set_text_map_propagator(TraceContextPropagator::new());
    let exporter = TestSpanExporter::default();
    let tracer_provider = SdkTracerProvider::builder()
        .with_simple_exporter(exporter.clone())
        .build();
    let tracer = tracer_provider.tracer("daemon-http-tests");
    let subscriber =
        tracing_subscriber::registry().with(tracing_opentelemetry::layer().with_tracer(tracer));
    let _subscriber_guard = tracing::subscriber::set_default(subscriber);

    let app = Router::new()
        .route(
            "/v1/projects/{project_id}",
            get(|| async { axum::Json(serde_json::json!({ "ok": true })) }),
        )
        .layer(middleware::from_fn(crate::daemon::http::trace_http_request));
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let addr = listener.local_addr().expect("listener addr");
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve router");
    });

    {
        let parent_span = tracing::info_span!("monitor.http.client", otel.kind = "client");
        let _parent_guard = parent_span.enter();
        let headers = crate::telemetry::current_trace_headers();
        let client = reqwest::Client::new();
        let mut request = client.get(format!("http://{addr}/v1/projects/demo"));
        for (header, value) in &headers {
            request = request.header(header, value);
        }
        let response = request.send().await.expect("send request");
        assert_eq!(response.status(), reqwest::StatusCode::OK);
    }

    server.abort();
    let _ = server.await;
    let _ = tracer_provider.force_flush();

    let spans = exporter.finished_spans();
    let parent_span = find_exported_span(&spans, "monitor.http.client");
    let request_span = find_exported_span(&spans, "GET /v1/projects/{project_id}");

    assert_eq!(request_span.span_kind, SpanKind::Server);
    assert_eq!(
        request_span.parent_span_id,
        parent_span.span_context.span_id()
    );
    assert_eq!(
        request_span.span_context.trace_id(),
        parent_span.span_context.trace_id()
    );
    assert_eq!(
        span_string_attribute(request_span, "http.route").as_deref(),
        Some("/v1/projects/{project_id}")
    );
    assert_eq!(
        span_string_attribute(request_span, "url.path").as_deref(),
        Some("/v1/projects/{project_id}")
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
